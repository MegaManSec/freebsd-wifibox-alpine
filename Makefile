PREFIX?=/usr/local
LOCALBASE?=/usr/local
MINIROOTFS?=$(PWD)/alpine-minirootfs.tar.gz
PACKAGES?=$(PWD)/*.apk

ROOT=$(PREFIX)/share/wifibox
SHAREDIR=$(DESTDIR)$(ROOT)
ETCDIR=$(DESTDIR)$(PREFIX)/etc/wifibox
MANDIR=$(DESTDIR)$(PREFIX)/man
RUNDIR=$(DESTDIR)/var/run/wifibox

WORKDIR?=$(PWD)/work
BOOTSTRAPDIR=$(WORKDIR)/bootstrap
GUESTDIR=$(WORKDIR)/image-contents

BOOTDIR=$(GUESTDIR)/boot

SHAREMODE?=0644

ENV=/usr/bin/env
MKDIR=/bin/mkdir
CP=/bin/cp
SED=/usr/bin/sed
TAR=/usr/bin/tar
FIND=/usr/bin/find
RM=/bin/rm
LN=/bin/ln
GZIP=/usr/bin/gzip
INSTALL_DATA=/usr/bin/install -m $(SHAREMODE)
TOUCH=/usr/bin/touch
GIT=$(LOCALBASE)/bin/git
PATCHELF=$(LOCALBASE)/bin/patchelf
BRANDELF=/usr/bin/brandelf
MKSQUASHFS=$(LOCALBASE)/bin/mksquashfs

ELF_INTERPRETER=	/lib/ld-musl-x86_64.so.1
APK=			sbin/apk

_APK=			$(BOOTSTRAPDIR)/$(APK)

.if !empty(INITRD_FILES)
INITRD_IMG=		$(BOOTDIR)/initramfs
.endif

SQUASHFS_COMP?=		lzo
SQUASHFS_IMG=		$(PWD)/alpine-$(VERSION).squashfs.img
SQUASHFS_VMLINUZ=	$(BOOTDIR)/vmlinuz*

BOOT_SERVICES=		networking urandom bootmisc modules hostname hwclock sysctl syslog \
			wpa_supplicant wpa_passthru
DEFAULT_SERVICES=	acpid crond iptables udhcpd
SYSINIT_SERVICES=	devfs dmesg hwdrivers mdev

.if !defined(VERSION)
VERSION!=	$(GIT) describe --tags --always
.endif

SUB_LIST=	PREFIX=$(PREFIX) \
		LOCALBASE=$(LOCALBASE) \
		ROOT=$(ROOT)

_SUB_LIST_EXP=  ${SUB_LIST:S/$/!g/:S/^/ -e s!%%/:S/=/%%!/}

APPLIANCEDIR=	$(RUNDIR)/appliance

$(GUESTDIR)/.done:
	$(RM) -rf \
		$(GUESTDIR) \
		$(BOOTSTRAPDIR)
	$(MKDIR) -p \
		$(GUESTDIR) \
		$(BOOTSTRAPDIR)
	$(TAR) -xf $(MINIROOTFS) -C $(BOOTSTRAPDIR)
	# add packages without chroot(8)
	$(PATCHELF) \
		--set-interpreter $(BOOTSTRAPDIR)$(ELF_INTERPRETER) \
		$(_APK)
	$(BRANDELF) -t Linux $(_APK)
	$(ENV) LD_LIBRARY_PATH=$(BOOTSTRAPDIR)/lib \
		$(_APK) add \
			--initdb \
			--no-network \
			--no-cache \
			--force-non-repository \
			--allow-untrusted \
			--no-progress \
			--clean-protected \
			--root $(GUESTDIR) \
			--no-scripts \
			--no-chown \
			$(PACKAGES)
	# install extra firmware files manually
.if exists($(PWD)/guest/lib/firmware)
	$(CP) -R $(PWD)/guest/lib/firmware/ $(GUESTDIR)/lib/firmware
.endif
	# rc-update add
.for runlevel in boot default sysinit
.for service in $(${runlevel:tu}_SERVICES)
	$(LN) -s /etc/init.d/${service} $(GUESTDIR)/etc/runlevels/${runlevel}
.endfor
.endfor
	$(TOUCH) $(GUESTDIR)/.done

image-contents: $(GUESTDIR)/.done

EXCLUDE_FIRMWARE_FILES=	$(WORKDIR)/exclude_firmware.files

.if defined(FIRMWARE_FILES)
.for fw_file in $(FIRMWARE_FILES)
__FW_FILES+=		-name ${fw_file} -or
.endfor
_FW_FILES=		-not \( ${__FW_FILES:S/ -or$//W} \)
_EXCLUDE_FW_FILES= 	-ef $(EXCLUDE_FIRMWARE_FILES)
.else
_EXCLUDE_FW_FILES=
.endif

$(SQUASHFS_IMG): image-contents
.if defined(_FW_FILES)
	(cd $(GUESTDIR) \
		&& $(FIND) lib/firmware -not -type d -and $(_FW_FILES) \
		> $(EXCLUDE_FIRMWARE_FILES))
.endif
	$(MKSQUASHFS) \
		$(GUESTDIR) \
		$(SQUASHFS_IMG) \
		-all-root \
		-comp $(SQUASHFS_COMP) \
		-wildcards \
		$(_EXCLUDE_FW_FILES) \
		-e boot -e .done -e "var/*"

_TARGETS=	$(SQUASHFS_IMG)

all:	$(_TARGETS)

install:
	$(MKDIR) -p $(SHAREDIR)
	$(INSTALL_DATA) $(SQUASHFS_VMLINUZ) $(SHAREDIR)/vmlinuz
	$(INSTALL_DATA) $(SQUASHFS_IMG) $(SHAREDIR)/disk.img
	$(SED) ${_SUB_LIST_EXP} share/grub.cfg > $(SHAREDIR)/grub.cfg

	$(MKDIR) -p $(ETCDIR)
	$(CP) etc/* $(ETCDIR)/

	$(MKDIR) -p $(MANDIR)/man5
	$(SED) ${_SUB_LIST_EXP} man/wifibox-alpine.5 \
	  | $(GZIP) -c > $(MANDIR)/man5/wifibox-alpine.5.gz

	$(MKDIR) -p $(APPLIANCEDIR)
	$(CP) -R $(GUESTDIR)/var/* $(APPLIANCEDIR)/
	$(RM) -rf $(APPLIANCEDIR)/lock
	$(LN) -s /run/lock $(APPLIANCEDIR)/lock

clean:
	$(RM) -rf $(GUESTDIR)
	$(RM) -f $(SQUASHFS_IMG)

.MAIN:	all
