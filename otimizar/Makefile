ARCHS = arm64
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

THEOS_DEVICE_IP=192.168.0.181

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CameraPreviewTweak

# Adiciona flags de otimização
CameraPreviewTweak_FILES = Tweak.xm logger.m DarwinNotifications.m
CameraPreviewTweak_LIBRARIES = substrate
CameraPreviewTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# Adiciona regra para limpar arquivos temporários
after-clean::
	rm -rf ./packages
	rm -rf ./.theos
