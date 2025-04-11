Projeto iOS WebRTC Camera Substitution
Visão Geral
Este projeto permite substituir o feed da câmera de um dispositivo iOS em tempo real utilizando streaming WebRTC. Similar à substituição com arquivos MP4, esta solução recebe um stream de vídeo remoto via WebRTC e o utiliza para substituir o feed da câmera nativa do iOS, permitindo que aplicativos que usam a câmera vejam o conteúdo transmitido em vez da imagem capturada pela câmera física.
Arquitetura
O projeto é dividido em três componentes principais:

Servidor WebRTC: Responsável pela sinalização WebRTC entre o transmissor e o dispositivo iOS
Interface Web: Permite ao usuário capturar e transmitir vídeo de alta qualidade
Tweak para iOS: Intercepta o fluxo da câmera e substitui por frames recebidos via WebRTC

Fases do Projeto
Fase 1: Otimização do Servidor WebRTC (✅ Concluído)
Desenvolvimento de um servidor WebRTC otimizado para redes locais 5GHz, focado em qualidade e baixa latência.

Implementação de servidor WebSocket para sinalização WebRTC
Otimização para stream 4K (3840x2160) a 60fps
Configuração para alta qualidade de vídeo e baixa latência
Priorização de codec H.264 para melhor compatibilidade com iOS
Sistema de salas para conexões múltiplas
Logging e monitoramento avançado

Fase 2: Interface Web Otimizada (✅ Concluído)
Desenvolvimento de uma interface web para capturar e transmitir vídeo.

Suporte para câmeras de alta resolução (até 4K)
Configuração de qualidade de vídeo e framerates de até 60fps
Estatísticas em tempo real e indicadores de qualidade de conexão
Detecção automática de dispositivos e configurações
Compatibilidade com vários navegadores e dispositivos
Design responsivo e feedback visual do estado da conexão

Fase 3: Modificação do WebRTCManager (✅ Concluído)
Adaptação do WebRTCManager existente para servir como provedor de frames para o sistema de substituição de câmera.

Criar método para acessar o último frame recebido do stream WebRTC
Implementar conversão de RTCVideoFrame para CMSampleBuffer
Otimizar o recebimento e processamento dos frames para baixa latência
Manter compatibilidade com diferentes formatos de pixel usados no iOS

Fase 4: Sistema de Substituição de Câmera (⏳ Pendente)
Implementação do mecanismo para substituir o feed da câmera nativa do iOS.

Portar hooks do AVCaptureVideoDataOutput do código base existente
Integrar com o WebRTCManager para usar frames do stream
Implementar camadas visuais para preview
Criar sistema toggle para ativar/desativar substituição via botão "Conectar"

Fase 5: Integração e Otimização (⏳ Pendente)
Integração de todos os componentes e otimização do sistema completo.

Garantir sincronização eficiente entre recebimento WebRTC e requisições de câmera
Otimizar gestão de memória e conversão de formatos
Melhorar tratamento de erros e reconexões
Testes em aplicativos reais de câmera
Polimento da interface do usuário e feedbacks visuais

Tecnologias Utilizadas

Servidor: Node.js, Express, ws (WebSocket)
Cliente Web: HTML, CSS, JavaScript, WebRTC API
iOS Tweak: Objective-C, WebRTC Framework, AVFoundation
Build System: Theos/Logos

Vantagens em Relação à Substituição via MP4

Conteúdo dinâmico: Permite transmitir qualquer conteúdo em tempo real, não limitado a um arquivo pré-gravado
Controle remoto: Possibilidade de controlar o feed da câmera remotamente (de outro dispositivo ou PC)
Flexibilidade: Suporta diversas fontes de vídeo, incluindo webcams, capturas de tela, e mais
Adaptabilidade: O WebRTC se adapta automaticamente às condições da rede, ajustando qualidade conforme necessário

Requisitos de Rede

Rede WiFi 5GHz local recomendada para melhor desempenho
Largura de banda mínima de 15-25 Mbps para qualidade Full HD
Largura de banda de 35-50 Mbps recomendada para qualidade 4K
Latência abaixo de 50ms para melhor experiência

Status Atual

✅ Servidor WebRTC otimizado implementado e testado
✅ Interface web desenvolvida e funcional
🔄 Adaptação do WebRTCManager em andamento
⏳ Sistema de substituição de câmera pendente
⏳ Integração final e otimização pendentes


Este README serve como um guia completo do projeto, descrevendo suas fases, componentes e status atual. O projeto aproveita o poder do WebRTC para criar uma solução mais dinâmica e flexível para substituição do feed da câmera em dispositivos iOS, superando as limitações da abordagem baseada em arquivos MP4.
