TARGET := iphone:clang:latest:12.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KillSwitch
KillSwitch_FILES = KillSwitch.xm
KillSwitch_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
KillSwitch_FRAMEWORKS = UIKit Foundation
KillSwitch_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
