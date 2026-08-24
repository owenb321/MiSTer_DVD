TARCHIVE=backup/mpeg2-backup.tar

clean:
	$(MAKE) -C bench/ clean
	$(MAKE) -C synth/ clean
#	$(MAKE) -C tools/mpeg2enc/ clean

tar: clean
	date > doc/timestamp
	tar cvf $(TARCHIVE) doc/ rtl/ bench synth/ tools/
	ls -l $(TARCHIVE)
	mv $(TARCHIVE) backup/mpeg2-`date +%d%m%y-%T`.tar
