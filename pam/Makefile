CC = clang
CFLAGS = -Wall -Wextra -Werror -O2 -std=c11 -fPIC
LDFLAGS = -lpam -framework Security -framework CoreFoundation
SDK = $(shell xcrun --show-sdk-path)
INCLUDES = -isysroot $(SDK)

TARGET = pam_touchbridge.so
SOURCES = pam_touchbridge.c tb_peer_verify.c
HEADERS = pam_touchbridge.h tb_peer_verify.h

TEST_BIN = test_peer_verify

PAM_INSTALL_DIR = /usr/local/lib/pam

.PHONY: all clean test install

all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(INCLUDES) -arch arm64 -shared -o pam_touchbridge_arm64.so $(SOURCES) $(LDFLAGS)
	$(CC) $(CFLAGS) $(INCLUDES) -arch x86_64 -shared -o pam_touchbridge_x86_64.so $(SOURCES) $(LDFLAGS)
	lipo -create pam_touchbridge_arm64.so pam_touchbridge_x86_64.so -output $(TARGET)
	@rm -f pam_touchbridge_arm64.so pam_touchbridge_x86_64.so
	@echo "Built $(TARGET) (universal binary)"

# Host-arch test binary for the daemon identity checks. Exercises the peer
# verification against a real Unix socket served by a signed system binary,
# and (informationally) against a running TouchBridge daemon if present.
$(TEST_BIN): test_peer_verify.c tb_peer_verify.c tb_peer_verify.h
	$(CC) $(CFLAGS) $(INCLUDES) -o $(TEST_BIN) test_peer_verify.c tb_peer_verify.c -framework Security -framework CoreFoundation

test: $(TEST_BIN)
	./$(TEST_BIN)

# Install the module. Build first as your normal user (`make -C pam`), then
# `sudo make -C pam install`. The old file is removed before copying: writing
# over a signed Mach-O in place leaves the kernel with a stale signature and
# the next sudo dies with "Killed: 9".
install:
	@[ "$$(id -u)" = "0" ] || { echo "run as root: sudo make -C pam install"; exit 1; }
	@[ -f $(TARGET) ] || { echo "build first as your normal user: make -C pam"; exit 1; }
	mkdir -p $(PAM_INSTALL_DIR)
	rm -f $(PAM_INSTALL_DIR)/$(TARGET)
	cp $(TARGET) $(PAM_INSTALL_DIR)/$(TARGET)
	chown root:wheel $(PAM_INSTALL_DIR)/$(TARGET)
	chmod 444 $(PAM_INSTALL_DIR)/$(TARGET)
	@echo "Installed $(PAM_INSTALL_DIR)/$(TARGET)"

clean:
	rm -f $(TARGET) pam_touchbridge_arm64.so pam_touchbridge_x86_64.so $(TEST_BIN)
