TARGET := iphone:clang:latest:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MaltegoAI

MaltegoAI_FILES = main.m
MaltegoAI_FRAMEWORKS = UIKit AVFoundation Speech NaturalLanguage
MaltegoAI_CFLAGS = -fobjc-arc
MaltegoAI_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
