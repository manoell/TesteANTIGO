/**
 * WebRTC Signaling Server - Optimized with fixes for connection issues
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const os = require('os');

// Configuration
const PORT = process.env.PORT || 8080;
const MAX_CONNECTIONS_PER_ROOM = 10;  // Transmitter + receiver
const ROOM_DEFAULT = 'ios-camera';

// Setup Express app
const app = express();
app.use(cors({ origin: '*' }));
app.use(express.json());
app.use(express.static(__dirname));

// Create HTTP and WebSocket servers
const server = http.createServer(app);
const wss = new WebSocket.Server({ 
  server,
  maxPayload: 64 * 1024 * 1024  // 64MB max payload for 4K video
});

// Store connections and room data
const rooms = new Map();
const clients = new Map();

/**
 * Simple logging function with timestamp
 */
function log(message, isError = false) {
  const timestamp = new Date().toISOString();
  const formattedMsg = `[${timestamp}] ${message}`;
  
  isError ? console.error(formattedMsg) : console.log(formattedMsg);
}

/**
 * Class to manage a WebRTC room
 */
class Room {
  constructor(id) {
    this.id = id;
    this.clients = new Map(); // Changed to Map to store clientId -> client
    this.offers = [];
    this.answers = [];
    this.iceCandidates = [];
    this.created = new Date();
    this.lastActivity = new Date();
  }

  hasClient(clientId) {
    return this.clients.has(clientId);
  }

  addClient(client) {
    if (this.clients.has(client.id)) {
      log(`Client ${client.id} already in room ${this.id}, ignoring duplicate join`);
      return this.clients.size;
    }
    
    this.clients.set(client.id, client);
    client.roomId = this.id;
    this.lastActivity = new Date();
    return this.clients.size;
  }

  removeClient(client) {
    if (!client || !client.id) return false;
    const removed = this.clients.delete(client.id);
    if (removed) {
      this.lastActivity = new Date();
      log(`Client ${client.id} removed from room ${this.id}, remaining: ${this.clients.size}`);
    }
    return removed;
  }

  broadcast(message, exceptClientId = null) {
    const msgString = typeof message === 'string' 
      ? message 
      : JSON.stringify(message);
      
    this.clients.forEach((client, id) => {
      if (id !== exceptClientId && client.readyState === WebSocket.OPEN) {
        client.send(msgString);
      }
    });
  }

  isEmpty() {
    return this.clients.size === 0;
  }

  storeMessage(type, message) {
    message.timestamp = Date.now();
    
    if (type === 'offer') {
      this.offers.push(message);
      if (this.offers.length > 5) this.offers.shift();
    } 
    else if (type === 'answer') {
      this.answers.push(message);
      if (this.answers.length > 5) this.answers.shift();
    }
    else if (type === 'ice-candidate') {
      // Check if this is a duplicate candidate - we need to be extremely careful about the comparison
      // since ice candidates can be very similar but different in subtle ways
      const isDuplicate = this.iceCandidates.some(c => 
        c.senderId === message.senderId && 
        c.candidate === message.candidate && 
        c.sdpMid === message.sdpMid && 
        c.sdpMLineIndex === message.sdpMLineIndex
      );
      
      if (!isDuplicate) {
        this.iceCandidates.push(message);
        // Limit the number but keep enough for reconnection
        if (this.iceCandidates.length > 50) this.iceCandidates.shift();
      } else {
        log(`Skipping duplicate ICE candidate from ${message.senderId}`);
      }
    }
  }

  // Return statistics about this room
  getStats() {
    return {
      id: this.id,
      clients: this.clients.size,
      created: this.created,
      lastActivity: this.lastActivity,
      offers: this.offers.length,
      answers: this.answers.length,
      iceCandidates: this.iceCandidates.length
    };
  }
}

/**
 * Get or create a room
 */
function getOrCreateRoom(roomId) {
  if (!rooms.has(roomId)) {
    rooms.set(roomId, new Room(roomId));
    log(`New room created: ${roomId}`);
  }
  return rooms.get(roomId);
}

/**
 * Clean closed connections from rooms
 */
function cleanupRooms() {
  let removedClients = 0;
  let removedRooms = 0;
  
  // First clean up clients that are no longer connected
  rooms.forEach((room, id) => {
    room.clients.forEach((client, clientId) => {
      if (client.readyState === WebSocket.CLOSED || client.readyState === WebSocket.CLOSING) {
        room.removeClient(client);
        delete client.roomId;
        removedClients++;
      }
    });
    
    // Then remove empty rooms
    if (room.isEmpty()) {
      rooms.delete(id);
      removedRooms++;
    }
  });
  
  if (removedClients > 0 || removedRooms > 0) {
    log(`Cleanup: removed ${removedClients} disconnected clients and ${removedRooms} empty rooms. Remaining rooms: ${rooms.size}`);
  }
}

// Setup periodic cleanup
setInterval(cleanupRooms, 10000);

/**
 * Analyze SDP quality for logging
 */
function analyzeSdpQuality(sdp) {
  if (!sdp) return { hasVideo: false };
  
  const result = {
    hasVideo: sdp.includes('m=video'),
    hasAudio: sdp.includes('m=audio'),
    hasH264: sdp.includes('H264'),
    resolution: "unknown",
    fps: "unknown"
  };
  
  // Try to extract resolution
  const resMatch = sdp.match(/a=imageattr:.*send.*\[x=([0-9]+)\-?([0-9]+)?\,y=([0-9]+)\-?([0-9]+)?]/i);
  if (resMatch && resMatch.length >= 4) {
    const width = resMatch[2] || resMatch[1];
    const height = resMatch[4] || resMatch[3];
    result.resolution = `${width}x${height}`;
  }
  
  // Try to extract FPS
  const fpsMatch = sdp.match(/a=framerate:([0-9]+)/i);
  if (fpsMatch && fpsMatch.length >= 2) {
    result.fps = `${fpsMatch[1]}fps`;
  }
  
  return result;
}

/**
 * Optimize SDP for high quality video - with fix for duplicate rtx payload
 */
function enhanceSdpForHighQuality(sdp) {
  if (!sdp.includes('m=video')) return sdp;
  
  // Check if SDP already contains high bitrate settings
  if (sdp.includes('b=AS:20000')) {
    return sdp; // Already optimized, don't modify to avoid duplicates
  }
  
  const lines = sdp.split('\n');
  const newLines = [];
  let inVideoSection = false;
  let videoSectionModified = false;
  
  // Keep track of payload types to avoid duplicates
  const seenPayloads = new Set();
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Check for rtpmap lines with rtx codec to avoid duplicates
    if (line.startsWith('a=rtpmap:') && line.includes('rtx/')) {
      // Extract payload type (the number after "a=rtpmap:")
      const payloadMatch = line.match(/^a=rtpmap:(\d+)\s/);
      if (payloadMatch) {
        const payloadType = payloadMatch[1];
        if (seenPayloads.has(payloadType)) {
          // Skip duplicate payload type
          continue;
        }
        seenPayloads.add(payloadType);
      }
    }
    
    // Detect video section
    if (line.startsWith('m=video')) {
      inVideoSection = true;
    } else if (line.startsWith('m=')) {
      inVideoSection = false;
    }
    
    // For video section, add bitrate if it doesn't exist
    if (inVideoSection && line.startsWith('c=') && !videoSectionModified) {
      newLines.push(line);
      // Add high bitrate line for 4K after connection line
      newLines.push(`b=AS:20000`);
      videoSectionModified = true;
      continue;
    }
    
    // Modify H264 profile-level-id to support 4K, but only if not already set
    if (inVideoSection && line.includes('profile-level-id') && line.includes('H264')) {
      // Only replace if not already high profile
      if (!line.includes('profile-level-id=640032')) {
        const modifiedLine = line.replace(/profile-level-id=[0-9a-fA-F]+/i, 'profile-level-id=640032');
        newLines.push(modifiedLine);
        continue;
      }
    }
    
    newLines.push(line);
  }
  
  return newLines.join('\n');
}

// Handle WebSocket connections
wss.on('connection', (ws) => {
  // Assign a unique ID to this client
  const clientId = Date.now().toString(36) + Math.random().toString(36).substring(2);
  ws.id = clientId;
  ws.isAlive = true;
  clients.set(clientId, ws);
  
  log(`New WebSocket connection: ${clientId}`);
  
  // Handle pong messages to track connection status
  ws.on('pong', () => {
    ws.isAlive = true;
  });
  
  // Handle errors
  ws.on('error', (error) => {
    log(`WebSocket error: ${error.message}`, true);
  });
  
  // Process incoming messages
  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      const msgType = data.type;
      const msgRoomId = data.roomId || ROOM_DEFAULT;
      
      if (!msgType) {
        log(`Received message without type from ${ws.id}`, true);
        return;
      }
      
      log(`Received ${msgType} message from ${ws.id} for room ${msgRoomId}`);
      
      // Handle different message types
      switch (msgType) {
        case 'join':
          handleJoinMessage(ws, msgRoomId);
          break;
          
        case 'offer':
        case 'answer':
        case 'ice-candidate':
          handleRtcMessage(ws, msgType, data, msgRoomId);
          break;
          
        case 'bye':
          handleByeMessage(ws, msgRoomId);
          break;
          
        default:
          log(`Unknown message type: ${msgType}`, true);
      }
    } catch (e) {
      log(`Error processing message: ${e.message}`, true);
      ws.send(JSON.stringify({
        type: 'error', 
        message: 'Invalid message format'
      }));
    }
  });
  
  // Handle disconnection
  ws.on('close', () => {
    log(`Client ${ws.id} disconnected`);
    clients.delete(clientId);
    
    // Notify room about the departure if client was in a room
    if (ws.roomId && rooms.has(ws.roomId)) {
      const room = rooms.get(ws.roomId);
      
      // Notify other clients in the room
      room.broadcast({
        type: 'user-left',
        userId: ws.id
      });
      
      // Remove the client from the room
      room.removeClient(ws);
    }
  });
});

/**
 * Handle 'join' message
 */
function handleJoinMessage(ws, roomId) {
  // Check if we need to recreate a room (might have been deleted)
  if (!rooms.has(roomId)) {
    const room = getOrCreateRoom(roomId);
    log(`Room ${roomId} created for join request`);
  }

  const room = rooms.get(roomId);

  // Check if client is already in this room - prevent duplicate joins
  if (ws.roomId === roomId && room.hasClient(ws.id)) {
    log(`Client ${ws.id} already in room ${roomId}, ignoring duplicate join`);
    ws.send(JSON.stringify({
      type: 'info',
      message: `Already joined room ${roomId}`
    }));
    return;
  }

  // If client was in another room, remove them
  if (ws.roomId && rooms.has(ws.roomId)) {
    const oldRoom = rooms.get(ws.roomId);
    oldRoom.removeClient(ws);
    oldRoom.broadcast({
      type: 'user-left',
      userId: ws.id
    });
    log(`Client ${ws.id} left room ${ws.roomId} to join ${roomId}`);
    delete ws.roomId; // Explicitly remove the roomId property
  }
  
  // Check room capacity
  if (room.clients.size >= MAX_CONNECTIONS_PER_ROOM) {
    // Look for closed connections in the room
    let hasCleaned = false;
    room.clients.forEach((client, id) => {
      if (client.readyState === WebSocket.CLOSED || client.readyState === WebSocket.CLOSING) {
        room.removeClient(client);
        hasCleaned = true;
        log(`Removed disconnected client ${id} from room ${roomId}`);
      }
    });
    
    // If room is still full after cleanup
    if (room.clients.size >= MAX_CONNECTIONS_PER_ROOM && !hasCleaned) {
      ws.send(JSON.stringify({
        type: 'error',
        message: `Room '${roomId}' is full (max ${MAX_CONNECTIONS_PER_ROOM} clients)`
      }));
      log(`Join rejected, room ${roomId} is full`);
      return;
    }
  }
  
  // Add client to room
  const clientCount = room.addClient(ws);
  log(`Client ${ws.id} joined room ${roomId}, total clients: ${clientCount}`);
  
  // Notify other clients
  room.broadcast({
    type: 'user-joined',
    userId: ws.id
  }, ws.id);
  
  // Send most recent offer if available
  if (room.offers.length > 0) {
    const latestOffer = room.offers[room.offers.length - 1];
    ws.send(JSON.stringify(latestOffer));
  }
  
  // Send ICE candidates if available
  room.iceCandidates.forEach(candidate => {
    ws.send(JSON.stringify(candidate));
  });
  
  // Send room info to client
  ws.send(JSON.stringify({
    type: 'room-info',
    clients: room.clients.size,
    room: roomId
  }));
}

/**
 * Handle WebRTC messages (offer, answer, ice-candidate)
 */
function handleRtcMessage(ws, type, data, roomId) {
  // Make sure client is in the specified room
  if (!ws.roomId || ws.roomId !== roomId) {
    log(`Client ${ws.id} tried to send ${type} but is not in room ${roomId}`);
    ws.send(JSON.stringify({
      type: 'error',
      message: `You're not in room ${roomId}`
    }));
    return;
  }
  
  const room = rooms.get(roomId);
  if (!room) {
    log(`Room ${roomId} doesn't exist for ${type} message`);
    ws.send(JSON.stringify({
      type: 'error',
      message: `Room ${roomId} doesn't exist`
    }));
    return;
  }
  
  // Add sender ID to the message
  data.senderId = ws.id;
  
  // For offer or answer, log quality and optimize SDP if needed
  if ((type === 'offer' || type === 'answer') && data.sdp) {
    const quality = analyzeSdpQuality(data.sdp);
    log(`${type} quality: video=${quality.hasVideo}, resolution=${quality.resolution}, fps=${quality.fps}`);
    
    // Enhance SDP for high quality if it's an offer
    if (type === 'offer') {
      data.sdp = enhanceSdpForHighQuality(data.sdp);
    }
  }
  
  // Store the message in the room
  room.storeMessage(type, data);
  
  // Broadcast to all other clients in the room
  room.broadcast(data, ws.id);
}

/**
 * Handle 'bye' message
 */
function handleByeMessage(ws, roomId) {
  log(`Processing 'bye' message from client ${ws.id} for room ${roomId}`);
  
  // Validate the client is actually in this room
  if (!ws.roomId || ws.roomId !== roomId) {
    log(`Client ${ws.id} sent 'bye' but is not in room ${roomId}`);
    return;
  }
  
  const room = rooms.get(roomId);
  if (!room) {
    log(`Room ${roomId} doesn't exist for 'bye' message`);
    return;
  }
  
  // Notify other clients
  room.broadcast({
    type: 'peer-disconnected',
    userId: ws.id
  }, ws.id);
  
  // Remove client from room
  room.removeClient(ws);
  
  // Important: set roomId to null to prevent duplicate bye/leave issues
  ws.roomId = null;
  
  log(`Client ${ws.id} sent 'bye' and was removed from room ${roomId}`);
}

// Set up ping interval to keep connections alive
const pingInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (ws.isAlive === false) {
      log(`Terminating inactive connection: ${ws.id}`);
      return ws.terminate();
    }
    
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

// Clean up interval when server closes
wss.on('close', () => {
  clearInterval(pingInterval);
  log('WebSocket server closed');
});

// Define routes
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// Server info endpoint
app.get('/info', (req, res) => {
  const roomsInfo = {};
  
  rooms.forEach((room, id) => {
    roomsInfo[id] = room.getStats();
  });
  
  res.json({
    clients: wss.clients.size,
    rooms: rooms.size,
    roomsInfo: roomsInfo,
    uptime: process.uptime()
  });
});

// Room info endpoint
app.get('/room/:roomId/info', (req, res) => {
  const roomId = req.params.roomId;
  
  if (!rooms.has(roomId)) {
    return res.status(404).json({ error: 'Room not found' });
  }
  
  res.json(rooms.get(roomId).getStats());
});

// Get local IP addresses
function getLocalIPs() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  
  Object.keys(interfaces).forEach(interfaceName => {
    interfaces[interfaceName].forEach(iface => {
      // Ignore IPv6 and loopback
      if (iface.family === 'IPv4' && !iface.internal) {
        addresses.push(iface.address);
      }
    });
  });
  
  return addresses;
}

// Start server
server.listen(PORT, () => {
  const addresses = getLocalIPs();
  
  log(`WebRTC signaling server running on port ${PORT}`);
  log(`Available network interfaces: ${addresses.join(', ')}`);
  log(`Web interface available at http://localhost:${PORT}`);
});