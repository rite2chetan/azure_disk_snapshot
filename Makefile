# dummy Makefile for easy OBS "%makeinstall" package build
#
BINDIR := /usr/local/sbin

default:
	@echo "use make install DESTDIR=foo"

install:
	install -d $(DESTDIR)/etc/azure
	sed "s#@BINDIR@#$(BINDIR)#g" VMSnapshotScriptPluginConfig.json > $(DESTDIR)/etc/azure/VMSnapshotScriptPluginConfig.json
	chmod 0600 $(DESTDIR)/etc/azure/VMSnapshotScriptPluginConfig.json
	touch -r VMSnapshotScriptPluginConfig.json $(DESTDIR)/etc/azure/VMSnapshotScriptPluginConfig.json
	install -d $(DESTDIR)$(BINDIR)
	install -m 0700 -p AzureVMSnapDb2.sh $(DESTDIR)$(BINDIR)
