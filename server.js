/**
 * Servidor WebRTC Otimizado para Streaming de Alta Qualidade em Rede Local 5GHz
 * Especializado para stream de substituição de câmera iOS em tempo real
 * Otimizado para qualidade de vídeo e baixa latência
 */

const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const path = require('path');
const os = require('os');
const fs = require('fs');
const cluster = require('cluster');

// Configurações otimizadas para redes locais de alta velocidade
const CONFIG = {
  PORT: process.env.PORT || 8080,
  MAX_BITRATE: 50000, // 50Mbps para WiFi 5GHz
  MIN_BITRATE: 15000, // 15Mbps mínimo para manter qualidade
  H264_PROFILE: '640032', // High profile, Level 5.0 (4K suporte)
  H264_PROFILE_ALTERNATIVE: '42e032', // Perfil alternativo para maior compatibilidade
  TARGET_RESOLUTION: '3840x2160', // 4K UHD
  TARGET_FRAMERATE: 60,
  KEY_FRAME_INTERVAL: 60, // Solicitar keyframe a cada 60 frames (1 segundo em 60fps)
  PING_INTERVAL: 5000, // 5 segundos para detectar desconexões rapidamente
  CLEANUP_INTERVAL: 10000, // 10 segundos para limpeza de salas
  LOG_LEVEL: 'verbose', // verbose, info, warning, error
  MAX_PAYLOAD_SIZE: 64 * 1024 * 1024, // 64MB para permitir SDP grandes e candidatos ICE
  DEFAULT_ROOM: 'ios-camera',
  CONNECTION_TIMEOUT: 30000, // 30 segundos para timeout de conexão
  ENABLE_CLUSTERING: process.env.NODE_ENV === 'production', // Habilitar modo cluster em produção
  MAX_ROOMS: 100, // Limite de salas para prevenir DoS
  MAX_CLIENTS_PER_ROOM: 10, // Limite de clientes por sala
};

// Configurar app Express
const app = express();
app.use(cors({ origin: '*' }));
app.use(express.json({ limit: '2mb' })); // Limite para payloads JSON
app.use(express.static(path.join(__dirname)));

// Criar servidor HTTP e WebSocket
const server = http.createServer(app);
const wss = new WebSocket.Server({ 
  server,
  maxPayload: CONFIG.MAX_PAYLOAD_SIZE,
  perMessageDeflate: false, // Desativar compressão para reduzir latência
  clientTracking: true, // Rastrear clientes
  backlog: 1024, // Aumentar backlog para muitas conexões simultâneas
});

// Armazenar conexões e dados das salas
const rooms = new Map();
const clients = new Map();
const rateLimit = new Map(); // Para controle de rate limit
let serverStartTime = Date.now();

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
    
    // Criar ou truncar log no início
    try {
      if (process.env.NODE_ENV !== 'production') {
        fs.writeFileSync(this.logFile, `[${new Date().toISOString()}] WebRTC Server Started\n`, 'utf8');
      } else {
        // Em produção, apenas anexar mensagem de início
        fs.appendFileSync(this.logFile, `\n[${new Date().toISOString()}] WebRTC Server Started\n`);
        
        // Limitar tamanho do arquivo de log em produção (2MB)
        fs.stat(this.logFile, (err, stats) => {
          if (!err && stats.size > 2 * 1024 * 1024) {
            // Fazer backup do log antigo
            try {
              fs.renameSync(this.logFile, `${this.logFile}.old`);
              fs.writeFileSync(this.logFile, `[${new Date().toISOString()}] Log rotated\n`, 'utf8');
            } catch (e) {
              console.error('Error rotating log file:', e);
            }
          }
        });
      }
    } catch (e) {
      console.error('Error initializing log file:', e);
    }
  }
  
  _log(level, message) {
    if (this.levels[level] >= this.level) {
      const timestamp = new Date().toISOString();
      const processId = cluster.isWorker ? `[Worker ${process.pid}]` : '[Master]';
      const logMessage = `[${timestamp}]${processId}[${level.toUpperCase()}] ${message}`;
      
      console[level === 'warning' ? 'warn' : level](logMessage);
      
      // Registrar no arquivo também
      try {
        fs.appendFileSync(this.logFile, logMessage + '\n');
      } catch (e) {
        console.error('Error writing to log file:', e);
      }
      
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
    this.hostCandidates = new Map(); // senderId -> [host candidates] (para reconexão rápida)
    this.created = new Date();
    this.lastActivity = new Date();
    this.qualityMetrics = new Map(); // clientId -> metrics
    this.stats = {
      messagesExchanged: 0,
      peakClients: 0,
      reconnections: 0,
      bytesTransferred: 0,
      errors: 0
    };
    this.videoQualityConfig = {
      targetBitrate: CONFIG.MAX_BITRATE,
      targetResolution: CONFIG.TARGET_RESOLUTION,
      targetFramerate: CONFIG.TARGET_FRAMERATE,
      keyFrameInterval: CONFIG.KEY_FRAME_INTERVAL,
      preferredCodec: 'H264'
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
    
    // Verificar limite de clientes por sala
    if (this.clients.size >= CONFIG.MAX_CLIENTS_PER_ROOM) {
      throw new Error(`Sala ${this.id} atingiu o limite máximo de ${CONFIG.MAX_CLIENTS_PER_ROOM} clientes`);
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
        if (id !== exceptClientId && client && client.readyState === WebSocket.OPEN) {
          client.send(msgString);
          sentCount++;
          
          // Estimar bytes transferidos
          this.stats.bytesTransferred += msgString.length;
        }
      });
      
      if (sentCount > 0) {
        this.stats.messagesExchanged++;
        logger.verbose(`Mensagem broadcast enviada para ${sentCount} clientes na sala ${this.id}`);
      }
      
      return sentCount;
    } catch (error) {
      this.stats.errors++;
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
          message.originalSdp = message.sdp; // Armazenar SDP original para diagnóstico
          message.sdp = enhanceSdpForHighQuality(message.sdp, this.videoQualityConfig);
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
            
            // Armazenar também na lista de candidatos host para reconexão rápida
            if (!this.hostCandidates.has(message.senderId)) {
              this.hostCandidates.set(message.senderId, []);
            }
            
            const hostCandidatesList = this.hostCandidates.get(message.senderId);
            if (!hostCandidatesList.some(c => c.candidate === message.candidate)) {
              hostCandidatesList.push(message);
              
              // Manter apenas os 5 melhores candidatos host
              if (hostCandidatesList.length > 5) {
                hostCandidatesList.pop();
              }
            }
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
        
      case 'quality-report':
        // Armazenar métricas de qualidade
        this.updateQualityMetrics(message.senderId, message.metrics);
        break;
        
      default:
        logger.verbose(`Mensagem de tipo ${type} não armazenada`);
    }
  }

  updateQualityMetrics(clientId, metrics) {
    if (!clientId || !metrics) return;
    
    this.qualityMetrics.set(clientId, {
      timestamp: Date.now(),
      metrics: metrics
    });
    
    // Analisar métricas e ajustar configurações se necessário
    this.analyzeQualityMetrics();
  }
  
  analyzeQualityMetrics() {
    if (!this.qualityMetrics || this.qualityMetrics.size === 0) return;
    
    // Calcular médias de FPS, bitrate, etc
    let totalFps = 0;
    let totalBitrate = 0;
    let totalLatency = 0;
    let count = 0;
    
    for (const [clientId, data] of this.qualityMetrics.entries()) {
      if (!data || !data.metrics) continue;
      
      const {metrics} = data;
      if (metrics.fps) totalFps += metrics.fps;
      if (metrics.bitrate) totalBitrate += metrics.bitrate;
      if (metrics.latency) totalLatency += metrics.latency;
      count++;
    }
    
    if (count === 0) return;
    
    const avgFps = totalFps / count;
    const avgBitrate = totalBitrate / count;
    const avgLatency = totalLatency / count;
    
    logger.info(`Métricas médias para sala ${this.id}: FPS=${avgFps.toFixed(1)}, Bitrate=${avgBitrate.toFixed(0)}kbps, Latência=${avgLatency.toFixed(0)}ms`);
    
    // Aplicar ajustes se necessário
    let configChanged = false;
    
    // Se FPS muito baixo mas bitrate alto, reduzir bitrate temporariamente
    if (avgFps < this.videoQualityConfig.targetFramerate * 0.7 && 
        avgBitrate > CONFIG.MIN_BITRATE * 1.5) {
      
      const newBitrate = Math.max(avgBitrate * 0.8, CONFIG.MIN_BITRATE);
      this.videoQualityConfig.targetBitrate = newBitrate;
      configChanged = true;
      
      logger.info(`Reduzindo bitrate para ${newBitrate.toFixed(0)}kbps na sala ${this.id} devido ao baixo FPS`);
    }
    
    // Se latência for alta, reduzir tamanho do buffer
    if (avgLatency > 200 && this.videoQualityConfig.keyFrameInterval > 30) {
      this.videoQualityConfig.keyFrameInterval = 30;
      configChanged = true;
      
      logger.info(`Reduzindo intervalo de keyframes para 30 na sala ${this.id} devido à alta latência`);
    }
    
    // Notificar clientes se houve mudança
    if (configChanged) {
      this.broadcast({
        type: 'quality-adjustment',
        config: this.videoQualityConfig,
        reason: 'Otimização automática baseada em métricas',
        timestamp: Date.now()
      });
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
      hostCandidatesCount: Array.from(this.hostCandidates.values())
        .reduce((sum, candidates) => sum + candidates.length, 0),
      videoQualityConfig: this.videoQualityConfig,
      ...this.stats,
      uptime: Math.floor((Date.now() - this.created) / 1000)
    };
  }
}

/**
 * Obter ou criar uma sala
 */
function getOrCreateRoom(roomId) {
  // Sanitizar roomId para evitar problemas
  roomId = roomId.replace(/[^a-zA-Z0-9_-]/g, '').substring(0, 50);
  
  if (roomId.length === 0) {
    roomId = CONFIG.DEFAULT_ROOM;
  }
  
  // Verificar o limite de salas
  if (!rooms.has(roomId) && rooms.size >= CONFIG.MAX_ROOMS) {
    // Limpar salas inativas se próximo do limite
    cleanupRooms(true);
    
    // Verificar novamente após limpeza
    if (rooms.size >= CONFIG.MAX_ROOMS) {
      throw new Error(`Limite de ${CONFIG.MAX_ROOMS} salas atingido. Tente novamente mais tarde.`);
    }
  }
  
  if (!rooms.has(roomId)) {
    rooms.set(roomId, new Room(roomId));
    logger.info(`Nova sala criada: ${roomId}`);
  }
  return rooms.get(roomId);
}

/**
 * Limpar conexões fechadas e salas vazias
 * @param {boolean} aggressive - Se true, remove salas mesmo com pouca atividade
 */
function cleanupRooms(aggressive = false) {
  let removedClients = 0;
  let removedRooms = 0;
  
  // Timestamp atual para comparação
  const now = Date.now();
  
  // Primeiro, limpar clientes que não estão mais conectados
  for (const [id, room] of rooms.entries()) {
    for (const [clientId, client] of room.clients.entries()) {
      if (client.readyState === WebSocket.CLOSED || client.readyState === WebSocket.CLOSING) {
        room.removeClient(client);
        clients.delete(clientId);
        removedClients++;
      }
    }
    
    // Em seguida, remover salas vazias ou inativas
    const lastActivityTime = room.lastActivity.getTime();
    const inactiveTime = now - lastActivityTime;
    
    if (room.isEmpty() || (aggressive && inactiveTime > 3600000)) { // 1 hora sem atividade
      rooms.delete(id);
      removedRooms++;
      logger.info(`Sala ${id} removida: ${room.isEmpty() ? 'vazia' : 'inativa por 1 hora'}`);
    }
  }
  
  // Limpar clientes sem sala
  for (const [clientId, client] of clients.entries()) {
    if (!client.roomId || !rooms.has(client.roomId)) {
      clients.delete(clientId);
      removedClients++;
    }
  }
  
  // Limpar rate limits antigos
  for (const [ip, time] of rateLimit.entries()) {
    if (now - time > 60000) { // 1 minuto
      rateLimit.delete(ip);
    }
  }
  
  if (removedClients > 0 || removedRooms > 0) {
    logger.info(`Limpeza: removidos ${removedClients} clientes desconectados e ${removedRooms} salas vazias. Salas restantes: ${rooms.size}`);
  }
  
  return { removedClients, removedRooms };
}

// Configurar limpeza periódica
setInterval(cleanupRooms, CONFIG.CLEANUP_INTERVAL);

/**
 * Verificar rate limit para IP
 * @param {string} ip - Endereço IP do cliente
 * @param {number} limit - Número máximo de requests em 1 minuto
 * @returns {boolean} - true se dentro do limite, false se excedeu
 */
function checkRateLimit(ip, limit = 100) {
  const now = Date.now();
  
  // Ignorar localhost e IPs de rede local para rate limit
  if (ip === '127.0.0.1' || ip === '::1' || ip.startsWith('192.168.') || ip.startsWith('10.')) {
    return true;
  }
  
  if (!rateLimit.has(ip)) {
    rateLimit.set(ip, { count: 1, firstRequest: now });
    return true;
  }
  
  const data = rateLimit.get(ip);
  
  // Resetar contador após 1 minuto
  if (now - data.firstRequest > 60000) {
    rateLimit.set(ip, { count: 1, firstRequest: now });
    return true;
  }
  
  // Incrementar contador
  data.count++;
  rateLimit.set(ip, data);
  
  // Verificar limite
  if (data.count > limit) {
    logger.warning(`Rate limit excedido para IP ${ip}: ${data.count} requests em menos de 1 minuto`);
    return false;
  }
  
  return true;
}

/**
 * Otimizar SDP para máxima qualidade e baixa latência em redes locais
 * @param {string} sdp - Session Description Protocol string
 * @param {object} qualityConfig - Configurações de qualidade
 * @return {string} - SDP otimizado
 */
function enhanceSdpForHighQuality(sdp, qualityConfig = {}) {
  if (!sdp) return sdp;
  
  // Usar configurações fornecidas ou padrões
  const config = {
    maxBitrate: qualityConfig.targetBitrate || CONFIG.MAX_BITRATE,
    targetResolution: qualityConfig.targetResolution || CONFIG.TARGET_RESOLUTION,
    targetFramerate: qualityConfig.targetFramerate || CONFIG.TARGET_FRAMERATE,
    keyFrameInterval: qualityConfig.keyFrameInterval || CONFIG.KEY_FRAME_INTERVAL,
    h264Profile: CONFIG.H264_PROFILE,
    preferH264: true
  };
  
  const lines = sdp.split('\n');
  const newLines = [];
  let inVideoSection = false;
  let videoSectionModified = false;
  let h264PayloadType = null;
  
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
    
    // Detectar seção de vídeo
    if (line.startsWith('m=video')) {
      inVideoSection = true;
      
      // Reordenar codecs para priorizar H.264
      if (config.preferH264 && (line.includes('H264') || line.includes('VP8') || line.includes('VP9'))) {
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
                
                // Armazenar o payload type de H.264 para uso posterior
                if (codec === 'H264') {
                  h264PayloadType = payload;
                }
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
      newLines.push(`b=AS:${config.maxBitrate}`); // Taxa de bits alta para rede local
      newLines.push(`b=TIAS:${config.maxBitrate * 1000}`); // Também especificar em kbps
      videoSectionModified = true;
      continue;
    }
    
    // Modificar profile-level-id de H.264 para suportar 4K e alta taxa de bits
    if (inVideoSection && line.includes('profile-level-id') && line.includes('H264')) {
      // Substituir por perfil de alta qualidade
      const modifiedLine = line.replace(/profile-level-id=[0-9a-fA-F]+/i, `profile-level-id=${config.h264Profile}`);
      
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
      if (payload === h264PayloadType || line.includes('profile-level-id')) {
        // Adicionar parâmetros para qualidade de vídeo H.264
        let updatedLine = line;
        
        if (!updatedLine.includes('profile-level-id')) {
          updatedLine += `;profile-level-id=${config.h264Profile}`;
        } else {
          updatedLine = updatedLine.replace(/profile-level-id=[0-9a-fA-F]+/i, `profile-level-id=${config.h264Profile}`);
        }
        
        // Adicionar parâmetros adicionais para streaming de alta qualidade
        const h264Params = {
          'level-asymmetry-allowed': '1',
          'packetization-mode': '1',
          'max-fr': config.targetFramerate.toString(),
          'max-mbps': '489600', // Para suportar 4K
          'max-fs': '35280'     // Para suportar 4K
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
    if (inVideoSection && line.startsWith('a=rtpmap:') && line.includes('H264')) {
      const hasFramerate = lines.some(l => l.startsWith('a=framerate:'));
      
      newLines.push(line);
      
      if (!hasFramerate) {
        // Adicionar framerate alto para H.264
        newLines.push(`a=framerate:${config.targetFramerate}`);
        
        // Adicionar key-frame-interval se não existir em outro lugar
        const payload = line.match(/^a=rtpmap:(\d+)/)[1];
        let hasKeyFrameInterval = false;
        
        for (let j = 0; j < lines.length; j++) {
          if (lines[j].includes('key-frame-interval') || 
              lines[j].includes('keyint') || 
              lines[j].includes('max-fr')) {
            hasKeyFrameInterval = true;
            break;
          }
        }
        
        if (!hasKeyFrameInterval) {
          newLines.push(`a=fmtp:${payload} key-frame-interval=${config.keyFrameInterval}`);
        }
        
        continue;
      }
    }
    
    // Configurar x-google-* parâmetros para Chrome
    if (inVideoSection) {
      if (line.includes('x-google-max-bitrate')) {
        newLines.push(`a=x-google-max-bitrate:${config.maxBitrate}`);
        continue;
      }
      if (line.includes('x-google-min-bitrate')) {
        newLines.push(`a=x-google-min-bitrate:${Math.floor(config.maxBitrate * 0.5)}`);
        continue;
      }
      if (line.includes('x-google-start-bitrate')) {
        newLines.push(`a=x-google-start-bitrate:${Math.floor(config.maxBitrate * 0.7)}`);
        continue;
      }
    }
    
    // Manter todas as outras linhas intactas
    newLines.push(line);
  }
  
  const result = newLines.join('\n');
  
  // Registro para verificação em modo verbose
  logger.verbose(`SDP original: ${sdp.length} bytes`);
  logger.verbose(`SDP otimizado: ${result.length} bytes`);
  
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
  // Verificar rate limit
  const clientIP = req.socket.remoteAddress || '0.0.0.0';
  if (!checkRateLimit(clientIP)) {
    ws.close(1008, 'Rate limit exceeded');
    return;
  }

  // Atribuir um ID único a este cliente
  const clientId = `${Date.now().toString(36)}-${Math.random().toString(36).substring(2)}`;
  ws.id = clientId;
  ws.isAlive = true;
  ws.connectedAt = Date.now();
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
  
  // Configurar timeout para conexões
  const connectionTimeout = setTimeout(() => {
    if (ws.readyState === WebSocket.OPEN && !ws.roomId) {
      logger.warning(`Timeout de conexão para ${ws.id} - não entrou em nenhuma sala após ${CONFIG.CONNECTION_TIMEOUT/1000}s`);
      ws.close(1000, 'Connection timeout - no room joined');
    }
  }, CONFIG.CONNECTION_TIMEOUT);
  
  // Lidar com erros
  ws.on('error', (error) => {
    logger.error(`Erro WebSocket (${clientId}): ${error.message}`);
    clearTimeout(connectionTimeout);
  });
  
  // Processar mensagens recebidas
  ws.on('message', (message) => {
    try {
      // Limitar tamanho da mensagem para evitar problemas
      if (message.length > CONFIG.MAX_PAYLOAD_SIZE) {
        logger.warning(`Mensagem muito grande recebida de ${ws.id}: ${message.length} bytes`);
        ws.send(JSON.stringify({
          type: 'error',
          message: 'Mensagem muito grande',
          timestamp: Date.now()
        }));
        return;
      }
      
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
          // Cancelar timeout de conexão quando o cliente entra em uma sala
          clearTimeout(connectionTimeout);
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
          
        case 'reconnect':
          handleReconnectionMessage(ws, data, msgRoomId);
          break;
          
        case 'quality-report':
          handleQualityReport(ws, data, msgRoomId);
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
    clients.delete(ws.id);
    clearTimeout(connectionTimeout);
    
    // Notificar sala sobre a partida se o cliente estava em uma sala
    if (ws.roomId && rooms.has(ws.roomId)) {
      const room = rooms.get(ws.roomId);
      
      // Notificar outros clientes na sala
      room.broadcast({
        type: 'user-left',
        userId: ws.id,
        timestamp: Date.now()
      }, ws.id);
      
      // Remover o cliente da sala
      room.removeClient(ws);
    }
  });

  // Enviar informações iniciais do servidor para o cliente
  try {
    ws.send(JSON.stringify({
      type: 'server-info',
      version: '2.1.0',
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
      }, ws.id);
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
      targetBitrate: room.videoQualityConfig.targetBitrate,
      preferH264: true,
      targetResolution: room.videoQualityConfig.targetResolution,
      targetFramerate: room.videoQualityConfig.targetFramerate,
      keyFrameInterval: room.videoQualityConfig.keyFrameInterval,
      timestamp: Date.now()
    }));
    
    // Enviar oferta mais recente se disponível
    if (room.offers.length > 0) {
      const latestOffer = room.offers[room.offers.length - 1];
      ws.send(JSON.stringify(latestOffer));
    }
    
    // Enviar candidatos ICE relevantes - priorizar host candidates para conexão rápida
    const hostCandidatesSent = new Set();
    
    // Primeiro enviar candidatos host (conexão local direta)
    for (const [senderId, candidates] of room.hostCandidates.entries()) {
      // Enviar apenas os 5 melhores candidatos host por cliente
      for (let i = 0; i < Math.min(candidates.length, 5); i++) {
        ws.send(JSON.stringify(candidates[i]));
        hostCandidatesSent.add(`${senderId}-${candidates[i].candidate}`);
      }
    }
    
    // Depois enviar outros candidatos ICE (não duplicar os host já enviados)
    for (const [senderId, candidates] of room.iceCandidates.entries()) {
      // Enviar apenas os 10 primeiros candidatos por cliente para evitar sobrecarga
      let count = 0;
      for (let i = 0; i < candidates.length && count < 10; i++) {
        const candidate = candidates[i];
        
        // Pular se já enviamos este candidato host
        if (candidate.candidate && 
            candidate.candidate.includes('typ host') && 
            hostCandidatesSent.has(`${senderId}-${candidate.candidate}`)) {
          continue;
        }
        
        ws.send(JSON.stringify(candidate));
        count++;
      }
    }
    
    // Enviar informações da sala para o cliente
    ws.send(JSON.stringify({
      type: 'room-info',
      clients: room.clients.size,
      room: roomId,
      videoQualityConfig: room.videoQualityConfig,
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
        data.sdp = enhanceSdpForHighQuality(data.sdp, room.videoQualityConfig);
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

/**
 * Lidar com solicitação de reconexão rápida
 */
function handleReconnectionMessage(ws, data, roomId) {
  try {
    const room = rooms.get(roomId);
    if (!room) {
      ws.send(JSON.stringify({
        type: 'error',
        message: `Sala ${roomId} não existe`,
        timestamp: Date.now()
      }));
      return;
    }
    
    // Verificar se o cliente já está na sala
    if (!ws.roomId || ws.roomId !== roomId) {
      // Adicionar cliente à sala primeiro
      room.addClient(ws);
      ws.roomId = roomId;
    }
    
    logger.info(`Cliente ${ws.id} solicitando reconexão rápida para sala ${roomId}`);
    room.stats.reconnections++;
    
    // Enviar imediatamente os melhores candidatos host
    let hostCandidatesCount = 0;
    if (room.hostCandidates.size > 0) {
      for (const [senderId, candidates] of room.hostCandidates.entries()) {
        // Enviar apenas os melhores candidatos host para reconexão rápida
        for (let i = 0; i < Math.min(candidates.length, 5); i++) {
          ws.send(JSON.stringify(candidates[i]));
          hostCandidatesCount++;
        }
      }
    }
    
    // Enviar a última oferta disponível
    if (room.offers.length > 0) {
      ws.send(JSON.stringify(room.offers[room.offers.length - 1]));
    }
    
    // Notificar outros clientes
    room.broadcast({
      type: 'peer-reconnecting',
      userId: ws.id,
      timestamp: Date.now()
    }, ws.id);
    
    // Enviar confirmação
    ws.send(JSON.stringify({
      type: 'reconnect-response',
      success: true,
      hostCandidates: hostCandidatesCount,
      videoQualityConfig: room.videoQualityConfig,
      timestamp: Date.now()
    }));
    
    logger.info(`Enviados dados de reconexão rápida para ${ws.id}: ${hostCandidatesCount} candidatos host`);
  } catch (error) {
    logger.error(`Erro ao processar reconexão para ${ws.id}: ${error.message}`);
    try {
      ws.send(JSON.stringify({
        type: 'error',
        message: `Erro na reconexão rápida`,
        details: error.message
      }));
    } catch (e) {
      // Ignorar erros ao enviar mensagens de erro
    }
  }
}

/**
 * Processar relatório de qualidade
 */
function handleQualityReport(ws, data, roomId) {
  try {
    if (!ws.roomId || ws.roomId !== roomId || !rooms.has(roomId)) {
      return;
    }
    
    const room = rooms.get(roomId);
    
    // Verificar se temos métricas válidas
    if (!data.metrics) {
      return;
    }
    
    // Atualizar métricas de qualidade para este cliente
    room.updateQualityMetrics(ws.id, data.metrics);
    
    // Enviar confirmação se solicitado
    if (data.requireAck) {
      ws.send(JSON.stringify({
        type: 'quality-report-ack',
        timestamp: Date.now()
      }));
    }
  } catch (error) {
    logger.error(`Erro ao processar relatório de qualidade de ${ws.id}: ${error.message}`);
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

// Página principal
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
    uptime: Math.floor((Date.now() - serverStartTime) / 1000),
    clients: clients.size,
    rooms: rooms.size,
    roomsInfo: roomsInfo,
    config: {
      maxBitrate: CONFIG.MAX_BITRATE,
      minBitrate: CONFIG.MIN_BITRATE,
      targetResolution: CONFIG.TARGET_RESOLUTION,
      targetFramerate: CONFIG.TARGET_FRAMERATE,
      keyFrameInterval: CONFIG.KEY_FRAME_INTERVAL
    },
    version: '2.1.0',
    system: {
      platform: process.platform,
      arch: process.arch,
      nodeVersion: process.version,
      cpus: os.cpus().length,
      memory: {
        total: Math.round(os.totalmem() / (1024 * 1024)),
        free: Math.round(os.freemem() / (1024 * 1024)),
        usage: Math.round((1 - os.freemem() / os.totalmem()) * 100)
      }
    }
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

// Endpoint para enviar relatório de qualidade
app.post('/quality-report', (req, res) => {
  try {
    const {roomId, clientId, metrics} = req.body;
    
    if (!roomId || !metrics) {
      return res.status(400).json({error: 'Dados inválidos'});
    }
    
    if (!rooms.has(roomId)) {
      return res.status(404).json({error: 'Sala não encontrada'});
    }
    
    const room = rooms.get(roomId);
    
    // Armazenar métricas de qualidade
    room.updateQualityMetrics(clientId || 'http-client', metrics);
    
    res.json({success: true});
  } catch (error) {
    res.status(500).json({error: error.message});
  }
});

// Endpoint para forçar limpeza de salas (administração)
app.post('/admin/cleanup', (req, res) => {
  const before = {
    rooms: rooms.size,
    clients: clients.size
  };
  
  const {removedClients, removedRooms} = cleanupRooms(true);
  
  const after = {
    rooms: rooms.size,
    clients: clients.size
  };
  
  res.json({
    success: true,
    before,
    after,
    cleaned: {
      rooms: removedRooms,
      clients: removedClients
    }
  });
});

// Endpoint de diagnóstico (somente em dev)
if (process.env.NODE_ENV !== 'production') {
  app.get('/debug/rooms', (req, res) => {
    const roomList = [];
    
    rooms.forEach((room, id) => {
      const clientList = [];
      room.clients.forEach((client, clientId) => {
        clientList.push({
          id: clientId,
          readyState: client.readyState,
          connectedAt: client.connectedAt
        });
      });
      
      roomList.push({
        id,
        clients: clientList,
        offers: room.offers.length,
        answers: room.answers.length,
        iceCandidates: Array.from(room.iceCandidates.keys()).length,
        hostCandidates: Array.from(room.hostCandidates.keys()).length,
        created: room.created,
        lastActivity: room.lastActivity
      });
    });
    
    res.json({
      rooms: roomList,
      totalClients: clients.size
    });
  });
}

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

/**
 * Função para iniciar o servidor
 */
function startServer() {
  server.listen(CONFIG.PORT, () => {
    const addresses = getLocalIPs();
    
    logger.info(`Servidor WebRTC Otimizado v2.1.0 rodando na porta ${CONFIG.PORT}`);
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
}

/**
 * Função principal para inicializar o servidor com suporte a múltiplos cores
 */
function initServer() {
  // Se estamos no modo de produção e somos o processo master, criar workers
  if (CONFIG.ENABLE_CLUSTERING && cluster.isMaster) {
    const numCPUs = os.cpus().length;
    const numWorkers = Math.max(2, Math.min(numCPUs - 1, 4)); // Usar 2-4 cores
    
    logger.info(`Iniciando servidor em modo cluster com ${numWorkers} workers`);
    
    for (let i = 0; i < numWorkers; i++) {
      cluster.fork();
    }
    
    cluster.on('exit', (worker, code, signal) => {
      logger.warning(`Worker ${worker.process.pid} morreu (${signal || code}). Reiniciando...`);
      cluster.fork();
    });
  } else {
    // Worker ou modo de desenvolvimento: iniciar servidor normalmente
    startServer();
  }
}

// Iniciar o servidor
initServer();