ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := FloatingBall

TARGET_CC := $(shell xcrun --sdk iphoneos --find clang)
TARGET_CXX := $(shell xcrun --sdk iphoneos --find clang++)
TARGET_LD := $(shell xcrun --sdk iphoneos --find clang++)

include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = FloatingBall

SRC_DIR := src
APP_DIR := $(SRC_DIR)/app
BRIDGING_DIR := $(SRC_DIR)/bridging
CONTROLLERS_DIR := $(SRC_DIR)/controllers
EXTENSIONS_DIR := $(SRC_DIR)/extensions
HELPERS_DIR := $(SRC_DIR)/helpers
PRIV_DIR := $(HELPERS_DIR)/private_headers
TS_DIR := $(HELPERS_DIR)/ts
HUD_DIR := $(SRC_DIR)/hud
VIEWS_DIR := $(SRC_DIR)/views

$(APPLICATION_NAME)_USE_MODULES := 0
$(APPLICATION_NAME)_FILES += $(wildcard $(APP_DIR)/*.mm)
$(APPLICATION_NAME)_FILES += $(wildcard $(BRIDGING_DIR)/*.m)
$(APPLICATION_NAME)_FILES += $(wildcard $(CONTROLLERS_DIR)/*.swift)
$(APPLICATION_NAME)_FILES += $(wildcard $(EXTENSIONS_DIR)/*.swift)
$(APPLICATION_NAME)_FILES += $(wildcard $(PRIV_DIR)/*.m)
$(APPLICATION_NAME)_FILES += $(wildcard $(TS_DIR)/*.mm)
$(APPLICATION_NAME)_FILES += $(wildcard $(HUD_DIR)/*.mm)
$(APPLICATION_NAME)_FILES += $(wildcard $(VIEWS_DIR)/*.swift)

$(APPLICATION_NAME)_CFLAGS += -fobjc-arc
$(APPLICATION_NAME)_CFLAGS += -include hud-prefix.pch -Wno-deprecated-declarations
$(APPLICATION_NAME)_SWIFTFLAGS += -import-objc-header src/bridging/FloatingBall-Bridging-Header.h

$(APPLICATION_NAME)_FRAMEWORKS += CoreGraphics QuartzCore UIKit Foundation PhotosUI
$(APPLICATION_NAME)_PRIVATE_FRAMEWORKS += BackBoardServices GraphicsServices IOKit SpringBoardServices

ifeq ($(TARGET_CODESIGN),ldid)
$(APPLICATION_NAME)_CODESIGN_FLAGS += -Sent.plist
else
$(APPLICATION_NAME)_CODESIGN_FLAGS += --entitlements ent.plist $(TARGET_CODESIGN_FLAGS)
endif

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)cp -rp $(THEOS_STAGING_DIR)/Applications/FloatingBall.app $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)cd $(THEOS_STAGING_DIR); zip -qr FloatingBall.tipa Payload; cd -;$(ECHO_END)
