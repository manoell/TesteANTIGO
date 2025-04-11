/**
 * WebRTC Signaling Server - Otimizado para conexões de rede local 5GHz e vídeo 4K
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const os = require('os');

// Configuração
const PORT = process.env.PORT || 8080;
const MAX_CONNECTIONS_PER_ROOM = 10;  // Transmissor + receptor
const ROOM_DEFAULT = 'ios-camera';
const MAX_BITRATE = 30000; // 30Mbps para WiFi 5GHz

// Configurar app Express
const app = express();
app.use(cors({ origin: '*' }));
app.use(express.json());
app.use(express.static(__dirname));

// Criar servidor HTTP e WebSocket
const server = http.createServer(app);
const wss = new WebSocket.Server({ 
  server,
  maxPayload: 64 * 1024 * 1024  // 64MB payload máximo para vídeo 4K
});

// Armazenar conexões e dados das salas
const rooms = new Map();
const clients = new Map();

/**
 * Função de log simples com timestamp
 */
function log(message, isError = false) {
  const timestamp = new Date().toISOString();
  const formattedMsg = `[${timestamp}] ${message}`;
  
  isError ? console.error(formattedMsg) : console.log(formattedMsg);
}

/**
 * Classe para gerenciar uma sala WebRTC
 */
class Room {
  constructor(id) {
    this.id = id;
    this.clients = new Map(); // Alterado para Map para armazenar clientId -> client
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
      log(`Cliente ${client.id} já está na sala ${this.id}, ignorando entrada duplicada`);
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
      log(`Cliente ${client.id} removido da sala ${this.id}, restantes: ${this.clients.size}`);
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
      // Para ofertas, armazenar apenas a mais recente
      this.offers.push(message);
      if (this.offers.length > 2) this.offers.shift(); // Manter apenas as 2 últimas ofertas
    } 
    else if (type === 'answer') {
      // Para respostas, armazenar apenas a mais recente
      this.answers.push(message);
      if (this.answers.length > 2) this.answers.shift(); // Manter apenas as 2 últimas respostas
    }
    else if (type === 'ice-candidate') {
      // Para candidatos ICE, priorizar candidatos de tipo "host" (conexões locais diretas)
      // e filtrar duplicatas
      
      // Verificar se é candidato de tipo "host" (conexão direta, melhor para rede local)
      const isHostCandidate = message.candidate && message.candidate.includes('typ host');
      
      // Verificar se é um candidato duplicado
      const isDuplicate = this.iceCandidates.some(c => 
        c.senderId === message.senderId && 
        c.candidate === message.candidate && 
        c.sdpMid === message.sdpMid && 
        c.sdpMLineIndex === message.sdpMLineIndex
      );
      
      if (!isDuplicate) {
        // Se for candidato de tipo host ou se temos poucos candidatos, armazenar
        if (isHostCandidate || this.iceCandidates.length < 20) {
          this.iceCandidates.push(message);
          
          // Limitar a quantidade total
          if (this.iceCandidates.length > 30) {
            // Remover candidatos não-host primeiro
            const nonHostCandidateIndex = this.iceCandidates.findIndex(c => 
              !c.candidate || !c.candidate.includes('typ host')
            );
            
            if (nonHostCandidateIndex >= 0) {
              this.iceCandidates.splice(nonHostCandidateIndex, 1);
            } else {
              // Se não houver candidatos não-host, remover o mais antigo
              this.iceCandidates.shift();
            }
          }
        }
      } else {
        log(`Ignorando candidato ICE duplicado de ${message.senderId}`);
      }
    }
  }

  // Retornar estatísticas sobre esta sala
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
 * Obter ou criar uma sala
 */
function getOrCreateRoom(roomId) {
  if (!rooms.has(roomId)) {
    rooms.set(roomId, new Room(roomId));
    log(`Nova sala criada: ${roomId}`);
  }
  return rooms.get(roomId);
}

/**
 * Limpar conexões fechadas das salas
 */
function cleanupRooms() {
  let removedClients = 0;
  let removedRooms = 0;
  
  // Primeiro, limpar clientes que não estão mais conectados
  rooms.forEach((room, id) => {
    room.clients.forEach((client, clientId) => {
      if (client.readyState === WebSocket.CLOSED || client.readyState === WebSocket.CLOSING) {
        room.removeClient(client);
        delete client.roomId;
        removedClients++;
      }
    });
    
    // Em seguida, remover salas vazias
    if (room.isEmpty()) {
      rooms.delete(id);
      removedRooms++;
    }
  });
  
  if (removedClients > 0 || removedRooms > 0) {
    log(`Limpeza: removidos ${removedClients} clientes desconectados e ${removedRooms} salas vazias. Salas restantes: ${rooms.size}`);
  }
}

// Configurar limpeza periódica
setInterval(cleanupRooms, 10000);

/**
 * Analisar qualidade do SDP para logging
 */
function analyzeSdpQuality(sdp) {
  if (!sdp) return { hasVideo: false };
  
  const result = {
    hasVideo: sdp.includes('m=video'),
    hasAudio: sdp.includes('m=audio'),
    hasH264: sdp.includes('H264'),
    resolution: "desconhecida",
    fps: "desconhecido"
  };
  
  // Tentar extrair resolução
  const resMatch = sdp.match(/a=imageattr:.*send.*\[x=([0-9]+)\-?([0-9]+)?\,y=([0-9]+)\-?([0-9]+)?]/i);
  if (resMatch && resMatch.length >= 4) {
    const width = resMatch[2] || resMatch[1];
    const height = resMatch[4] || resMatch[3];
    result.resolution = `${width}x${height}`;
  }
  
  // Tentar extrair FPS
  const fpsMatch = sdp.match(/a=framerate:([0-9]+)/i);
  if (fpsMatch && fpsMatch.length >= 2) {
    result.fps = `${fpsMatch[1]}fps`;
  }
  
  return result;
}

/**
 * Otimizar SDP para vídeo de alta qualidade - com correção para payload rtx duplicado
 */
function enhanceSdpForHighQuality(sdp) {
  if (!sdp.includes('m=video')) return sdp;
  
  // Verificar se o SDP já contém configurações de alta taxa de bits
  if (sdp.includes(`b=AS:${MAX_BITRATE}`)) {
    return sdp; // Já otimizado, não modificar para evitar duplicatas
  }
  
  const lines = sdp.split('\n');
  const newLines = [];
  let inVideoSection = false;
  let videoSectionModified = false;
  
  // Controlar tipos de payload para evitar duplicatas
  const seenPayloads = new Set();
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Verificar linhas rtpmap com codec rtx para evitar duplicatas
    if (line.startsWith('a=rtpmap:') && line.includes('rtx/')) {
      // Extrair tipo de payload (o número após "a=rtpmap:")
      const payloadMatch = line.match(/^a=rtpmap:(\d+)\s/);
      if (payloadMatch) {
        const payloadType = payloadMatch[1];
        if (seenPayloads.has(payloadType)) {
          // Ignorar tipo de payload duplicado
          continue;
        }
        seenPayloads.add(payloadType);
      }
    }
    
    // Detectar seção de vídeo
    if (line.startsWith('m=video')) {
      inVideoSection = true;
      
      // Reordenar codecs para priorizar H.264
      if (line.includes('H264')) {
        const parts = line.split(' ');
        if (parts.length > 3) {
          const newParts = [parts[0], parts[1], parts[2]];
          const payloadTypes = [];
          
          // Encontrar payload types para reordenar
          for (let j = 3; j < parts.length; j++) {
            payloadTypes.push(parts[j]);
          }
          
          // Reordenar para colocar H.264 na frente
          const h264Payloads = [];
          const otherPayloads = [];
          
          for (let p = 0; p < payloadTypes.length; p++) {
            const payload = payloadTypes[p];
            
            // Verificar se é um payload de H.264
            let isH264 = false;
            for (let k = i + 1; k < lines.length && !lines[k].startsWith('m='); k++) {
              if (lines[k].startsWith(`a=rtpmap:${payload} H264`)) {
                isH264 = true;
                break;
              }
            }
            
            if (isH264) {
              h264Payloads.push(payload);
            } else {
              otherPayloads.push(payload);
            }
          }
          
          // Adicionar primeiro H.264, depois os outros
          newParts.push(...h264Payloads);
          newParts.push(...otherPayloads);
          
          // Substituir a linha
          lines[i] = newParts.join(' ');
        }
      }
    } else if (line.startsWith('m=')) {
      inVideoSection = false;
    }
    
    // Para seção de vídeo, adicionar taxa de bits se não existir
    if (inVideoSection && line.startsWith('c=') && !videoSectionModified) {
      // Adicionar a linha original primeiro
      newLines.push(line);
      
      // Adicionar linha de alta taxa de bits para 4K em WiFi 5GHz
      newLines.push(`b=AS:${MAX_BITRATE}`);
      videoSectionModified = true;
      continue;
    }
    
    // Modificar profile-level-id de H.264 para suportar 4K e alta taxa de bits
    if (inVideoSection && line.includes('profile-level-id') && line.includes('H264')) {
      // Substituir apenas se ainda não está definido para alta qualidade
      if (!line.includes('profile-level-id=640032')) {
        const modifiedLine = line.replace(/profile-level-id=[0-9a-fA-F]+/i, 'profile-level-id=640032');
        
        // Adicionar packetization-mode=1 se não existir
        if (!modifiedLine.includes('packetization-mode')) {
          newLines.push(`${modifiedLine};packetization-mode=1`);
        } else {
          newLines.push(modifiedLine);
        }
        continue;
      }
    }
    
    // Configurar fmtp para alta qualidade
    if (inVideoSection && line.startsWith('a=fmtp:') && !line.includes('apt=')) {
      const payload = line.split(':')[1].split(' ')[0];
      
      // Verificar se este payload está relacionado a H.264
      let isH264 = false;
      for (let j = i - 1; j >= 0; j--) {
        if (lines[j].startsWith(`a=rtpmap:${payload} H264`)) {
          isH264 = true;
          break;
        }
      }
      
      if (isH264) {
        // Adicionar parâmetros para qualidade de vídeo H.264
        if (!line.includes('level-asymmetry-allowed')) {
          const updatedLine = line.replace(/profile-level-id=[0-9a-fA-F]+/i, 'profile-level-id=640032');
          
          // Adicionar parâmetros adicionais se necessário
          let finalLine = updatedLine;
          if (!finalLine.includes('level-asymmetry-allowed')) {
            finalLine = `${finalLine};level-asymmetry-allowed=1`;
          }
          if (!finalLine.includes('packetization-mode')) {
            finalLine = `${finalLine};packetization-mode=1`;
          }
          
          newLines.push(finalLine);
          continue;
        }
      }
    }
    
    newLines.push(line);
  }
  
  return newLines.join('\n');
}

// Lidar com conexões WebSocket
wss.on('connection', (ws, req) => {
  // Atribuir um ID único a este cliente
  const clientId = Date.now().toString(36) + Math.random().toString(36).substring(2);
  ws.id = clientId;
  ws.isAlive = true;
  clients.set(clientId, ws);
  
  // Verificar se a conexão é local
  const isLocalConnection = 
    req.socket.remoteAddress === '127.0.0.1' || 
    req.socket.remoteAddress === '::1' ||
    req.socket.remoteAddress.startsWith('192.168.') ||
    req.socket.remoteAddress.startsWith('10.') ||
    req.socket.remoteAddress.startsWith('172.16.');
  
  log(`Nova conexão WebSocket: ${clientId} de ${req.socket.remoteAddress} ${isLocalConnection ? '(local)' : '(remota)'}`);
  
  // Lidar com mensagens pong para rastrear status da conexão
  ws.on('pong', () => {
    ws.isAlive = true;
  });
  
  // Lidar com erros
  ws.on('error', (error) => {
    log(`Erro WebSocket: ${error.message}`, true);
  });
  
  // Processar mensagens recebidas
  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      const msgType = data.type;
      const msgRoomId = data.roomId || ROOM_DEFAULT;
      
      if (!msgType) {
        log(`Mensagem recebida sem tipo de ${ws.id}`, true);
        return;
      }
      
      log(`Recebida mensagem ${msgType} de ${ws.id} para sala ${msgRoomId}`);
      
      // Lidar com diferentes tipos de mensagem
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
          log(`Tipo de mensagem desconhecido: ${msgType}`, true);
      }
    } catch (e) {
      log(`Erro ao processar mensagem: ${e.message}`, true);
      ws.send(JSON.stringify({
        type: 'error', 
        message: 'Formato de mensagem inválido'
      }));
    }
  });
  
  // Lidar com desconexão
  ws.on('close', () => {
    log(`Cliente ${ws.id} desconectado`);
    clients.delete(clientId);
    
    // Notificar sala sobre a partida se o cliente estava em uma sala
    if (ws.roomId && rooms.has(ws.roomId)) {
      const room = rooms.get(ws.roomId);
      
      // Notificar outros clientes na sala
      room.broadcast({
        type: 'user-left',
        userId: ws.id
      });
      
      // Remover o cliente da sala
      room.removeClient(ws);
    }
  });
});

/**
 * Lidar com mensagem 'join'
 */
function handleJoinMessage(ws, roomId) {
  // Verificar se precisamos recriar uma sala (pode ter sido excluída)
  if (!rooms.has(roomId)) {
    const room = getOrCreateRoom(roomId);
    log(`Sala ${roomId} criada para solicitação de entrada`);
  }

  const room = rooms.get(roomId);

  // Verificar se o cliente já está nesta sala - evitar entradas duplicadas
  if (ws.roomId === roomId && room.hasClient(ws.id)) {
    log(`Cliente ${ws.id} já está na sala ${roomId}, ignorando entrada duplicada`);
    ws.send(JSON.stringify({
      type: 'info',
      message: `Já entrou na sala ${roomId}`
    }));
    return;
  }

  // Se o cliente estava em outra sala, removê-lo
  if (ws.roomId && rooms.has(ws.roomId)) {
    const oldRoom = rooms.get(ws.roomId);
    oldRoom.removeClient(ws);
    oldRoom.broadcast({
      type: 'user-left',
      userId: ws.id
    });
    log(`Cliente ${ws.id} saiu da sala ${ws.roomId} para entrar em ${roomId}`);
    delete ws.roomId; // Remover explicitamente a propriedade roomId
  }
  
  // Verificar capacidade da sala
  if (room.clients.size >= MAX_CONNECTIONS_PER_ROOM) {
    // Procurar conexões fechadas na sala
    let hasCleaned = false;
    room.clients.forEach((client, id) => {
      if (client.readyState === WebSocket.CLOSED || client.readyState === WebSocket.CLOSING) {
        room.removeClient(client);
        hasCleaned = true;
        log(`Removido cliente desconectado ${id} da sala ${roomId}`);
      }
    });
    
    // Se a sala ainda estiver cheia após a limpeza
    if (room.clients.size >= MAX_CONNECTIONS_PER_ROOM && !hasCleaned) {
      ws.send(JSON.stringify({
        type: 'error',
        message: `Sala '${roomId}' está cheia (máx ${MAX_CONNECTIONS_PER_ROOM} clientes)`
      }));
      log(`Entrada rejeitada, sala ${roomId} está cheia`);
      return;
    }
  }
  
  // Adicionar cliente à sala
  const clientCount = room.addClient(ws);
  log(`Cliente ${ws.id} entrou na sala ${roomId}, total de clientes: ${clientCount}`);
  
  // Notificar outros clientes
  room.broadcast({
    type: 'user-joined',
    userId: ws.id
  }, ws.id);
  
  // Enviar oferta mais recente se disponível
  if (room.offers.length > 0) {
    const latestOffer = room.offers[room.offers.length - 1];
    ws.send(JSON.stringify(latestOffer));
  }
  
  // Enviar candidatos ICE se disponíveis
  room.iceCandidates.forEach(candidate => {
    ws.send(JSON.stringify(candidate));
  });
  
  // Enviar informações da sala para o cliente
  ws.send(JSON.stringify({
    type: 'room-info',
    clients: room.clients.size,
    room: roomId
  }));
}

/**
 * Lidar com mensagens WebRTC (offer, answer, ice-candidate)
 */
function handleRtcMessage(ws, type, data, roomId) {
  // Garantir que o cliente esteja na sala especificada
  if (!ws.roomId || ws.roomId !== roomId) {
    log(`Cliente ${ws.id} tentou enviar ${type}, mas não está na sala ${roomId}`);
    ws.send(JSON.stringify({
      type: 'error',
      message: `Você não está na sala ${roomId}`
    }));
    return;
  }
  
  const room = rooms.get(roomId);
  if (!room) {
    log(`Sala ${roomId} não existe para mensagem ${type}`);
    ws.send(JSON.stringify({
      type: 'error',
      message: `Sala ${roomId} não existe`
    }));
    return;
  }
  
  // Adicionar ID do remetente à mensagem
  data.senderId = ws.id;
  
  // Para oferta ou resposta, registrar qualidade e otimizar SDP se necessário
  if ((type === 'offer' || type === 'answer') && data.sdp) {
    const quality = analyzeSdpQuality(data.sdp);
    log(`Qualidade ${type}: vídeo=${quality.hasVideo}, resolução=${quality.resolution}, fps=${quality.fps}`);
    
    // Aprimorar SDP para alta qualidade se for uma oferta
    if (type === 'offer') {
      data.sdp = enhanceSdpForHighQuality(data.sdp);
    }
  }
  
  // Armazenar a mensagem na sala
  room.storeMessage(type, data);
  
  // Transmitir para todos os outros clientes na sala
  room.broadcast(data, ws.id);
}

/**
 * Lidar com mensagem 'bye'
 */
function handleByeMessage(ws, roomId) {
  log(`Processando mensagem 'bye' do cliente ${ws.id} para sala ${roomId}`);
  
  // Validar se o cliente está realmente nesta sala
  if (!ws.roomId || ws.roomId !== roomId) {
    log(`Cliente ${ws.id} enviou 'bye', mas não está na sala ${roomId}`);
    return;
  }
  
  const room = rooms.get(roomId);
  if (!room) {
    log(`Sala ${roomId} não existe para mensagem 'bye'`);
    return;
  }
  
  // Notificar outros clientes
  room.broadcast({
    type: 'peer-disconnected',
    userId: ws.id
  }, ws.id);
  
  // Remover cliente da sala
  room.removeClient(ws);
  
  // Importante: definir roomId como null para evitar problemas de bye/leave duplicados
  ws.roomId = null;
  
  log(`Cliente ${ws.id} enviou 'bye' e foi removido da sala ${roomId}`);
}

// Configurar intervalo de ping para manter conexões ativas
const pingInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (ws.isAlive === false) {
      log(`Terminando conexão inativa: ${ws.id}`);
      return ws.terminate();
    }
    
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

// Limpar intervalo quando o servidor fechar
wss.on('close', () => {
  clearInterval(pingInterval);
  log('Servidor WebSocket fechado');
});

// Definir rotas
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

// Endpoint para informações do servidor
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

// Endpoint para informações da sala
app.get('/room/:roomId/info', (req, res) => {
  const roomId = req.params.roomId;
  
  if (!rooms.has(roomId)) {
    return res.status(404).json({ error: 'Sala não encontrada' });
  }
  
  res.json(rooms.get(roomId).getStats());
});

// Obter endereços IP locais
function getLocalIPs() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  
  Object.keys(interfaces).forEach(interfaceName => {
    interfaces[interfaceName].forEach(iface => {
      // Ignorar IPv6 e loopback
      if (iface.family === 'IPv4' && !iface.internal) {
        addresses.push(iface.address);
      }
    });
  });
  
  return addresses;
}

// Iniciar servidor
server.listen(PORT, () => {
  const addresses = getLocalIPs();
  
  log(`Servidor de sinalização WebRTC rodando na porta ${PORT}`);
  log(`Interfaces de rede disponíveis: ${addresses.join(', ')}`);
  log(`Interface web disponível em http://localhost:${PORT}`);
});