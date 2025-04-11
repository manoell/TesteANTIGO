/**
 * Servidor WebRTC Otimizado para Streaming de Alta Qualidade em Rede Local 5GHz
 * Especialmente projetado para redes locais de alta velocidade e baixa latência
 * Focado em stream para substituição de câmera iOS em tempo real
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const os = require('os');
const fs = require('fs');

// Configurações otimizadas para redes locais de alta velocidade
const CONFIG = {
  PORT: process.env.PORT || 8080,
  MAX_BITRATE: 50000, // 50Mbps para WiFi 5GHz
  H264_PROFILE: '640032', // High profile, Level 5.0 (4K suporte)
  TARGET_RESOLUTION: '3840x2160', // 4K UHD
  TARGET_FRAMERATE: 60,
  DEFAULT_ROOM: 'ios-camera',
  PING_INTERVAL: 5000, // 5 segundos para detectar desconexões rapidamente
  CLEANUP_INTERVAL: 10000, // 10 segundos para limpeza de salas
  LOG_LEVEL: 'verbose', // verbose, info, warning, error
  MAX_PAYLOAD_SIZE: 64 * 1024 * 1024, // 64MB para permitir SDP grandes e candidatos ICE
};

// Configurar app Express
const app = express();
app.use(cors({ origin: '*' }));
app.use(express.json());
app.use(express.static(path.join(__dirname)));

// Criar servidor HTTP e WebSocket
const server = http.createServer(app);
const wss = new WebSocket.Server({ 
  server,
  maxPayload: CONFIG.MAX_PAYLOAD_SIZE,
  perMessageDeflate: false // Desativar compressão para reduzir latência
});

// Armazenar conexões e dados das salas
const rooms = new Map();
const clients = new Map();

/**
 * Sistema de logging melhorado com níveis e timestamps
 */
class Logger {
  constructor(level = 'info') {
    this.levels = {
      verbose: 0,
      info: 1,
      warning: 2,
      error: 3
    };
    this.level = this.levels[level] || this.levels.info;
    this.logFile = 'webrtc-server.log';
    
    // Limpar log antigo no início
    if (process.env.NODE_ENV !== 'production') {
      fs.writeFileSync(this.logFile, '', 'utf8');
    }
  }
  
  _log(level, message) {
    if (this.levels[level] >= this.level) {
      const timestamp = new Date().toISOString();
      const logMessage = `[${timestamp}][${level.toUpperCase()}] ${message}`;
      
      console[level === 'warning' ? 'warn' : level](logMessage);
      
      // Registrar no arquivo também
      fs.appendFileSync(this.logFile, logMessage + '\n');
      
      return logMessage;
    }
  }
  
  verbose(message) { return this._log('verbose', message); }
  info(message) { return this._log('info', message); }
  warning(message) { return this._log('warning', message); }
  error(message) { return this._log('error', message); }
}

const logger = new Logger(CONFIG.LOG_LEVEL);

/**
 * Classe para gerenciar uma sala WebRTC com recursos avançados
 */
class Room {
  constructor(id) {
    this.id = id;
    this.clients = new Map(); // clientId -> client
    this.offers = [];
    this.answers = [];
    this.iceCandidates = new Map(); // senderId -> [candidates]
    this.created = new Date();
    this.lastActivity = new Date();
    this.stats = {
      messagesExchanged: 0,
      peakClients: 0,
      reconnections: 0
    };
  }

  hasClient(clientId) {
    return this.clients.has(clientId);
  }

  addClient(client) {
    if (this.clients.has(client.id)) {
      logger.verbose(`Cliente ${client.id} já está na sala ${this.id}, atualizando referência`);
      // Atualizar referência para o mesmo cliente
      this.clients.set(client.id, client);
      return this.clients.size;
    }
    
    this.clients.set(client.id, client);
    client.roomId = this.id;
    this.lastActivity = new Date();
    
    // Atualizar estatísticas
    this.stats.messagesExchanged++;
    if (this.clients.size > this.stats.peakClients) {
      this.stats.peakClients = this.clients.size;
    }
    
    return this.clients.size;
  }

  removeClient(client) {
    if (!client || !client.id) return false;
    const removed = this.clients.delete(client.id);
    if (removed) {
      this.lastActivity = new Date();
      logger.verbose(`Cliente ${client.id} removido da sala ${this.id}, restantes: ${this.clients.size}`);
    }
    return removed;
  }

  broadcast(message, exceptClientId = null) {
    try {
      const msgString = typeof message === 'string' 
        ? message 
        : JSON.stringify(message);
        
      let sentCount = 0;
      this.clients.forEach((client, id) => {
        if (id !== exceptClientId && client.readyState === WebSocket.OPEN) {
          client.send(msgString);
          sentCount++;
        }
      });
      
      if (sentCount > 0) {
        this.stats.messagesExchanged++;
        logger.verbose(`Mensagem broadcast enviada para ${sentCount} clientes na sala ${this.id}`);
      }
      
      return sentCount;
    } catch (error) {
      logger.error(`Erro no broadcast para sala ${this.id}: ${error.message}`);
      return 0;
    }
  }

  isEmpty() {
    return this.clients.size === 0;
  }

  storeMessage(type, message) {
    message.timestamp = Date.now();
    this.stats.messagesExchanged++;
    
    switch (type) {
      case 'offer':
        // Otimizar SDP para redes locais de alta velocidade e baixa latência
        if (message.sdp) {
          message.sdp = enhanceSdpForHighQuality(message.sdp);
          logger.verbose(`SDP de oferta otimizado para alta qualidade na sala ${this.id}`);
        }
        
        // Armazenar apenas a oferta mais recente
        this.offers = [message];
        break;
        
      case 'answer':
        // Armazenar apenas a resposta mais recente
        this.answers = [message];
        break;
        
      case 'ice-candidate':
        // Armazenamos candidatos por remetente para facilitar o envio específico
        if (!this.iceCandidates.has(message.senderId)) {
          this.iceCandidates.set(message.senderId, []);
        }
        
        const candidates = this.iceCandidates.get(message.senderId);
        
        // Verificar se é candidato de tipo "host" (conexão direta, melhor para rede local)
        const isHostCandidate = message.candidate && message.candidate.includes('typ host');
        
        // Verificar se é um candidato duplicado
        const isDuplicate = candidates.some(c => 
          c.candidate === message.candidate && 
          c.sdpMid === message.sdpMid && 
          c.sdpMLineIndex === message.sdpMLineIndex
        );
        
        if (!isDuplicate) {
          // Priorizar candidatos host (rede local)
          if (isHostCandidate) {
            // Candidatos host vão para o início da lista (maior prioridade)
            candidates.unshift(message);
          } else {
            // Outros candidatos vão para o final
            candidates.push(message);
          }
          
          // Limitar a quantidade total por cliente
          if (candidates.length > 30) {
            // Remover candidatos não-host primeiro
            const nonHostIndex = candidates.findIndex(c => 
              !c.candidate || !c.candidate.includes('typ host')
            );
            
            if (nonHostIndex >= 0) {
              candidates.splice(nonHostIndex, 1);
            } else {
              // Se não houver candidatos não-host, remover o mais antigo
              candidates.pop();
            }
          }
        } else {
          logger.verbose(`Ignorando candidato ICE duplicado de ${message.senderId}`);
        }
        break;
        
      default:
        logger.verbose(`Mensagem de tipo ${type} não armazenada`);
    }
  }

  // Retornar estatísticas detalhadas sobre esta sala
  getStats() {
    return {
      id: this.id,
      clients: this.clients.size,
      created: this.created,
      lastActivity: this.lastActivity,
      offers: this.offers.length,
      answers: this.answers.length,
      iceCandidatesCount: Array.from(this.iceCandidates.values())
        .reduce((sum, candidates) => sum + candidates.length, 0),
      ...this.stats
    };
  }
}

/**
 * Obter ou criar uma sala
 */
function getOrCreateRoom(roomId) {
  if (!rooms.has(roomId)) {
    rooms.set(roomId, new Room(roomId));
    logger.info(`Nova sala criada: ${roomId}`);
  }
  return rooms.get(roomId);
}

/**
 * Limpar conexões fechadas e salas vazias
 */
function cleanupRooms() {
  let removedClients = 0;
  let removedRooms = 0;
  
  // Primeiro, limpar clientes que não estão mais conectados
  for (const [id, room] of rooms.entries()) {
    for (const [clientId, client] of room.clients.entries()) {
      if (client.readyState === WebSocket.CLOSED || client.readyState === WebSocket.CLOSING) {
        room.removeClient(client);
        removedClients++;
      }
    }
    
    // Em seguida, remover salas vazias
    if (room.isEmpty()) {
      rooms.delete(id);
      removedRooms++;
    }
  }
  
  if (removedClients > 0 || removedRooms > 0) {
    logger.info(`Limpeza: removidos ${removedClients} clientes desconectados e ${removedRooms} salas vazias. Salas restantes: ${rooms.size}`);
  }
}

// Configurar limpeza periódica
setInterval(cleanupRooms, CONFIG.CLEANUP_INTERVAL);

/**
 * Otimizar SDP para máxima qualidade e baixa latência em redes locais
 * @param {string} sdp - Session Description Protocol string
 * @return {string} - SDP otimizado
 */
function enhanceSdpForHighQuality(sdp) {
  if (!sdp) return sdp;
  
  const lines = sdp.split('\n');
  const newLines = [];
  let inVideoSection = false;
  let videoSectionModified = false;
  
  // Controlar tipos de payload para evitar duplicatas
  const seenPayloads = new Set();
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    
    // Verificar duplicatas nos formatos RTX
    if (line.startsWith('a=rtpmap:') && line.includes('rtx/')) {
      const payloadMatch = line.match(/^a=rtpmap:(\d+)\s/);
      if (payloadMatch) {
        const payloadType = payloadMatch[1];
        if (seenPayloads.has(payloadType)) {
          continue; // Pular duplicata
        }
        seenPayloads.add(payloadType);
      }
    }
    
    // Detectar seção de vídeo e reordenar codecs
    if (line.startsWith('m=video')) {
      inVideoSection = true;
      
      // Reordenar codecs para priorizar H.264
      if (line.includes('H264') || line.includes('VP8') || line.includes('VP9')) {
        const parts = line.split(' ');
        if (parts.length > 3) {
          // Separar a linha em partes e payloads
          const prefix = parts.slice(0, 3);
          const payloads = parts.slice(3);
          
          // Separar e classificar os payloads por tipo de codec
          let codecPayloads = {
            'H264': [],
            'other': []
          };
          
          // Mapear payloads por codec
          let codecMap = new Map();
          
          // Primeiro passo: analisar linhas futuras para mapear payloads para codecs
          for (let j = i + 1; j < lines.length && !lines[j].startsWith('m='); j++) {
            const rtpmapLine = lines[j];
            if (rtpmapLine.startsWith('a=rtpmap:')) {
              const match = rtpmapLine.match(/^a=rtpmap:(\d+)\s([A-Za-z0-9]+)/);
              if (match && match.length >= 3) {
                const payload = match[1];
                const codec = match[2];
                codecMap.set(payload, codec);
              }
            }
          }
          
          // Segundo passo: classificar payloads
          for (const payload of payloads) {
            const codec = codecMap.get(payload);
            if (codec === 'H264') {
              codecPayloads['H264'].push(payload);
            } else {
              codecPayloads['other'].push(payload);
            }
          }
          
          // Recriar a linha com codecs priorizados
          const newLine = [...prefix, ...codecPayloads['H264'], ...codecPayloads['other']].join(' ');
          newLines.push(newLine);
          continue;
        }
      }
    } 
    else if (line.startsWith('m=')) {
      inVideoSection = false;
    }
    
    // Para seção de vídeo, adicionar taxa de bits alta para 4K
    if (inVideoSection && line.startsWith('c=') && !videoSectionModified) {
      newLines.push(line);
      newLines.push(`b=AS:${CONFIG.MAX_BITRATE}`); // Taxa de bits muito alta para rede local
      newLines.push(`b=TIAS:${CONFIG.MAX_BITRATE * 1000}`); // Também especificar em kbps
      videoSectionModified = true;
      continue;
    }
    
    // Modificar profile-level-id de H.264 para suportar 4K e alta taxa de bits
    if (inVideoSection && line.includes('profile-level-id') && line.includes('H264')) {
      // Substituir por perfil de alta qualidade
      const modifiedLine = line.replace(/profile-level-id=[0-9a-fA-F]+/i, `profile-level-id=${CONFIG.H264_PROFILE}`);
      
      // Adicionar packetization-mode=1 se não existir
      if (!modifiedLine.includes('packetization-mode')) {
        newLines.push(`${modifiedLine};packetization-mode=1`);
      } else {
        newLines.push(modifiedLine);
      }
      continue;
    }
    
    // Configurar fmtp para alta qualidade H.264
    if (inVideoSection && line.startsWith('a=fmtp:') && !line.includes('apt=')) {
      const payload = line.split(':')[1].split(' ')[0];
      
      // Verificar se este payload está relacionado a H.264
      let isH264 = false;
      for (let j = 0; j < lines.length; j++) {
        if (lines[j].startsWith(`a=rtpmap:${payload} H264`)) {
          isH264 = true;
          break;
        }
      }
      
      if (isH264) {
        // Adicionar parâmetros para qualidade de vídeo H.264
        let updatedLine = line;
        
        if (!updatedLine.includes('profile-level-id')) {
          updatedLine += `;profile-level-id=${CONFIG.H264_PROFILE}`;
        } else {
          updatedLine = updatedLine.replace(/profile-level-id=[0-9a-fA-F]+/i, `profile-level-id=${CONFIG.H264_PROFILE}`);
        }
        
        // Adicionar parâmetros adicionais para streaming de alta qualidade
        const h264Params = {
          'level-asymmetry-allowed': '1',
          'packetization-mode': '1',
          'sprop-parameter-sets': '', // Deixar vazio para ser preenchido pelo navegador
        };
        
        // Adicionar parâmetros que ainda não existem na linha
        for (const [param, value] of Object.entries(h264Params)) {
          if (value && !updatedLine.includes(`${param}=`)) {
            updatedLine += `;${param}=${value}`;
          }
        }
        
        newLines.push(updatedLine);
        continue;
      }
    }
    
    // Adicionar framerate mais alto se em seção de vídeo e não presente
    if (inVideoSection && (line.startsWith('a=rtpmap:') || line.startsWith('a=rtcp-fb:'))) {
      const hasFramerate = lines.some(l => l.startsWith('a=framerate:'));
      
      if (!hasFramerate && i > 0 && lines[i-1].startsWith('a=rtpmap:') && lines[i-1].includes('H264')) {
        // Adicionar framerate alto para H.264 após linha rtpmap
        newLines.push(line);
        newLines.push(`a=framerate:${CONFIG.TARGET_FRAMERATE}`);
        continue;
      }
    }
    
    // Configurar x-google-* parâmetros para Chrome
    if (inVideoSection && line.includes('x-google')) {
      // Ajustar parâmetros específicos do Chrome para alta qualidade
      if (line.includes('x-google-max-bitrate')) {
        newLines.push(`a=x-google-max-bitrate:${CONFIG.MAX_BITRATE}`);
        continue;
      }
      if (line.includes('x-google-min-bitrate')) {
        newLines.push(`a=x-google-min-bitrate:${Math.floor(CONFIG.MAX_BITRATE * 0.5)}`);
        continue;
      }
      if (line.includes('x-google-start-bitrate')) {
        newLines.push(`a=x-google-start-bitrate:${Math.floor(CONFIG.MAX_BITRATE * 0.7)}`);
        continue;
      }
    }
    
    // Manter todas as outras linhas intactas
    newLines.push(line);
  }
  
  const result = newLines.join('\n');
  
  // Registro para verificação
  logger.verbose(`SDP original:\n${sdp}`);
  logger.verbose(`SDP otimizado:\n${result}`);
  
  return result;
}

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
    fps: "desconhecido",
    bitrate: "desconhecido"
  };
  
  // Extrair resolução
  const resMatch = sdp.match(/a=imageattr:.*send.*\[x=([0-9]+)\-?([0-9]+)?\,y=([0-9]+)\-?([0-9]+)?]/i);
  if (resMatch && resMatch.length >= 4) {
    const width = resMatch[2] || resMatch[1];
    const height = resMatch[4] || resMatch[3];
    result.resolution = `${width}x${height}`;
  }
  
  // Extrair FPS
  const fpsMatch = sdp.match(/a=framerate:([0-9]+)/i);
  if (fpsMatch && fpsMatch.length >= 2) {
    result.fps = `${fpsMatch[1]}fps`;
  }
  
  // Extrair bitrate
  const bitrateMatch = sdp.match(/b=AS:([0-9]+)/i);
  if (bitrateMatch && bitrateMatch.length >= 2) {
    result.bitrate = `${bitrateMatch[1]}kbps`;
  }
  
  // H.264 profile level
  const profileMatch = sdp.match(/profile-level-id=([0-9a-fA-F]+)/i);
  if (profileMatch && profileMatch.length >= 2) {
    result.h264Profile = profileMatch[1];
  }
  
  return result;
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
  
  logger.info(`Nova conexão: ${clientId} de ${req.socket.remoteAddress} ${isLocalConnection ? '(local)' : '(remota)'}`);
  
  // Configuração para processar pings e configurar heartbeat
  ws.isAlive = true;
  ws.on('pong', () => {
    ws.isAlive = true;
  });
  
  // Lidar com erros
  ws.on('error', (error) => {
    logger.error(`Erro WebSocket (${clientId}): ${error.message}`);
  });
  
  // Processar mensagens recebidas
  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      const msgType = data.type;
      const msgRoomId = data.roomId || CONFIG.DEFAULT_ROOM;
      
      // Processar explicitamente mensagens keepalive do cliente
      if (msgType === 'keepalive') {
        // Responder com keepalive-ack e resetar isAlive
        ws.isAlive = true;
        ws.send(JSON.stringify({
          type: 'keepalive-ack',
          timestamp: Date.now()
        }));
        return; // Não processe mais esta mensagem
      }
      
      if (!msgType) {
        logger.warning(`Mensagem recebida sem tipo de ${ws.id}`);
        return;
      }
      
      logger.verbose(`Recebida mensagem ${msgType} de ${ws.id} para sala ${msgRoomId}`);
      
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
          logger.warning(`Tipo de mensagem desconhecido: ${msgType}`);
      }
    } catch (e) {
      logger.error(`Erro ao processar mensagem de ${ws.id}: ${e.message}`);
      try {
        ws.send(JSON.stringify({
          type: 'error', 
          message: 'Formato de mensagem inválido',
          details: e.message
        }));
      } catch (err) {
        // Ignorar erros ao enviar mensagens de erro
      }
    }
  });
  
  // Lidar com desconexão
  ws.on('close', () => {
    logger.info(`Cliente ${ws.id} desconectado`);
    clients.delete(clientId);
    
    // Notificar sala sobre a partida se o cliente estava em uma sala
    if (ws.roomId && rooms.has(ws.roomId)) {
      const room = rooms.get(ws.roomId);
      
      // Notificar outros clientes na sala
      room.broadcast({
        type: 'user-left',
        userId: ws.id,
        timestamp: Date.now()
      });
      
      // Remover o cliente da sala
      room.removeClient(ws);
    }
  });

  // Enviar informações iniciais do servidor para o cliente
  try {
    ws.send(JSON.stringify({
      type: 'server-info',
      version: '2.0.0',
      maxBitrate: CONFIG.MAX_BITRATE,
      preferredCodecs: ['H264'],
      defaultRoom: CONFIG.DEFAULT_ROOM,
      timestamp: Date.now()
    }));
  } catch (e) {
    logger.error(`Erro ao enviar informações iniciais: ${e.message}`);
  }
});

/**
 * Lidar com mensagem 'join'
 */
function handleJoinMessage(ws, roomId) {
  try {
    // Obter ou criar a sala
    const room = getOrCreateRoom(roomId);

    // Verificar se o cliente já está nesta sala
    if (ws.roomId === roomId && room.hasClient(ws.id)) {
      logger.verbose(`Cliente ${ws.id} já está na sala ${roomId}, ignorando entrada duplicada`);
      ws.send(JSON.stringify({
        type: 'info',
        message: `Já conectado à sala ${roomId}`,
        timestamp: Date.now()
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
      logger.verbose(`Cliente ${ws.id} saiu da sala ${ws.roomId} para entrar em ${roomId}`);
      delete ws.roomId;
    }
    
    // Adicionar cliente à sala
    const clientCount = room.addClient(ws);
    logger.info(`Cliente ${ws.id} entrou na sala ${roomId}, total: ${clientCount}`);
    
    // Notificar outros clientes
    room.broadcast({
      type: 'user-joined',
      userId: ws.id,
      timestamp: Date.now()
    }, ws.id);
    
    // Enviar configurações otimizadas para o cliente
    ws.send(JSON.stringify({
      type: 'connection-config',
      targetBitrate: CONFIG.MAX_BITRATE,
      preferH264: true,
      targetResolution: CONFIG.TARGET_RESOLUTION,
      targetFramerate: CONFIG.TARGET_FRAMERATE,
      timestamp: Date.now()
    }));
    
    // Enviar oferta mais recente se disponível
    if (room.offers.length > 0) {
      const latestOffer = room.offers[room.offers.length - 1];
      ws.send(JSON.stringify(latestOffer));
    }
    
    // Enviar candidatos ICE relevantes
    for (const [senderId, candidates] of room.iceCandidates.entries()) {
      // Enviar apenas os 10 primeiros candidatos por cliente para evitar sobrecarga
      for (let i = 0; i < Math.min(candidates.length, 10); i++) {
        ws.send(JSON.stringify(candidates[i]));
      }
    }
    
    // Enviar informações da sala para o cliente
    ws.send(JSON.stringify({
      type: 'room-info',
      clients: room.clients.size,
      room: roomId,
      timestamp: Date.now()
    }));
  } catch (error) {
    logger.error(`Erro ao processar join para ${ws.id}: ${error.message}`);
    try {
      ws.send(JSON.stringify({
        type: 'error',
        message: 'Erro ao entrar na sala',
        details: error.message
      }));
    } catch (e) {
      // Ignorar erros ao enviar mensagens de erro
    }
  }
}

/**
 * Lidar com mensagens WebRTC (offer, answer, ice-candidate)
 */
function handleRtcMessage(ws, type, data, roomId) {
  try {
    // Garantir que o cliente esteja na sala especificada
    if (!ws.roomId || ws.roomId !== roomId) {
      logger.warning(`Cliente ${ws.id} tentou enviar ${type}, mas não está na sala ${roomId}`);
      ws.send(JSON.stringify({
        type: 'error',
        message: `Você não está na sala ${roomId}`,
        timestamp: Date.now()
      }));
      return;
    }
    
    const room = rooms.get(roomId);
    if (!room) {
      logger.warning(`Sala ${roomId} não existe para mensagem ${type}`);
      ws.send(JSON.stringify({
        type: 'error',
        message: `Sala ${roomId} não existe`,
        timestamp: Date.now()
      }));
      return;
    }
    
    // Adicionar ID do remetente à mensagem
    data.senderId = ws.id;
    data.timestamp = Date.now();
    
    // Para oferta ou resposta, registrar qualidade e otimizar SDP
    if ((type === 'offer' || type === 'answer') && data.sdp) {
      const originalQuality = analyzeSdpQuality(data.sdp);
      logger.info(`Qualidade ${type} original: vídeo=${originalQuality.hasVideo}, resolução=${originalQuality.resolution}, fps=${originalQuality.fps}, bitrate=${originalQuality.bitrate}`);
      
      // Aprimorar SDP para alta qualidade
      if (type === 'offer') {
        data.sdp = enhanceSdpForHighQuality(data.sdp);
        const newQuality = analyzeSdpQuality(data.sdp);
        logger.info(`Qualidade ${type} otimizada: vídeo=${newQuality.hasVideo}, resolução=${newQuality.resolution}, fps=${newQuality.fps}, bitrate=${newQuality.bitrate}`);
      }
    }
    
    // Para candidatos ICE, adicionar timestamp e priorizar candidatos de rede local
    if (type === 'ice-candidate') {
      if (data.candidate && data.candidate.includes('typ host')) {
        logger.verbose(`Candidato ICE de tipo host recebido de ${ws.id}`);
        // Alta prioridade para candidatos de rede local
        data.priority = 'high';
      }
    }
    
    // Armazenar a mensagem na sala
    room.storeMessage(type, data);
    
    // Transmitir para todos os outros clientes na sala
    const sent = room.broadcast(data, ws.id);
    logger.verbose(`Mensagem ${type} enviada para ${sent} clientes na sala ${roomId}`);
  } catch (error) {
    logger.error(`Erro ao processar mensagem ${type} de ${ws.id}: ${error.message}`);
    try {
      ws.send(JSON.stringify({
        type: 'error',
        message: `Erro ao processar mensagem ${type}`,
        details: error.message
      }));
    } catch (e) {
      // Ignorar erros ao enviar mensagens de erro
    }
  }
}

/**
 * Lidar com mensagem 'bye'
 */
function handleByeMessage(ws, roomId) {
  try {
    logger.info(`Processando mensagem 'bye' do cliente ${ws.id} para sala ${roomId}`);
    
    // Validar se o cliente está realmente nesta sala
    if (!ws.roomId || ws.roomId !== roomId) {
      logger.warning(`Cliente ${ws.id} enviou 'bye', mas não está na sala ${roomId}`);
      return;
    }
    
    const room = rooms.get(roomId);
    if (!room) {
      logger.warning(`Sala ${roomId} não existe para mensagem 'bye'`);
      return;
    }
    
    // Notificar outros clientes
    room.broadcast({
      type: 'peer-disconnected',
      userId: ws.id,
      timestamp: Date.now()
    }, ws.id);
    
    // Remover cliente da sala
    room.removeClient(ws);
    
    // Definir roomId como null para evitar problemas
    ws.roomId = null;
    
    logger.info(`Cliente ${ws.id} enviou 'bye' e foi removido da sala ${roomId}`);
    
    // Enviar confirmação para o cliente
    ws.send(JSON.stringify({
      type: 'bye-ack',
      message: `Desconectado da sala ${roomId}`,
      timestamp: Date.now()
    }));
  } catch (error) {
    logger.error(`Erro ao processar bye de ${ws.id}: ${error.message}`);
  }
}

// Configurar intervalo de ping para manter conexões ativas
const pingInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (ws.isAlive === false) {
      logger.info(`Terminando conexão inativa: ${ws.id}`);
      return ws.terminate();
    }
    
    ws.isAlive = false;
    try {
      ws.ping();
    } catch (e) {
      logger.error(`Erro ao enviar ping para ${ws.id}: ${e.message}`);
      ws.terminate();
    }
  });
}, CONFIG.PING_INTERVAL);

// Limpar intervalo quando o servidor fechar
wss.on('close', () => {
  clearInterval(pingInterval);
  logger.info('Servidor WebSocket fechado');
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
    uptime: process.uptime(),
    config: {
      maxBitrate: CONFIG.MAX_BITRATE,
      targetResolution: CONFIG.TARGET_RESOLUTION,
      targetFramerate: CONFIG.TARGET_FRAMERATE
    },
    version: '2.0.0'
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

// Endpoint para forçar limpeza de salas (administração)
app.post('/admin/cleanup', (req, res) => {
  const before = {
    rooms: rooms.size,
    clients: clients.size
  };
  
  cleanupRooms();
  
  const after = {
    rooms: rooms.size,
    clients: clients.size
  };
  
  res.json({
    success: true,
    before,
    after,
    cleaned: {
      rooms: before.rooms - after.rooms,
      clients: before.clients - after.clients
    }
  });
});

// Obter endereços IP locais
function getLocalIPs() {
  const interfaces = os.networkInterfaces();
  const addresses = [];
  
  Object.keys(interfaces).forEach(interfaceName => {
    interfaces[interfaceName].forEach(iface => {
      // Ignorar IPv6 e loopback
      if (iface.family === 'IPv4' && !iface.internal) {
        addresses.push({
          address: iface.address,
          interface: interfaceName
        });
      }
    });
  });
  
  return addresses;
}

// Iniciar servidor
server.listen(CONFIG.PORT, () => {
  const addresses = getLocalIPs();
  
  logger.info(`Servidor WebRTC Otimizado v2.0.0 rodando na porta ${CONFIG.PORT}`);
  logger.info(`Configurado para: ${CONFIG.TARGET_RESOLUTION}@${CONFIG.TARGET_FRAMERATE}fps, ${CONFIG.MAX_BITRATE}kbps`);
  
  if (addresses.length > 0) {
    logger.info('Servidor disponível nos seguintes endereços:');
    addresses.forEach(addr => {
      logger.info(`- http://${addr.address}:${CONFIG.PORT} (${addr.interface})`);
    });
  } else {
    logger.info(`Interface web disponível em http://localhost:${CONFIG.PORT}`);
  }
});