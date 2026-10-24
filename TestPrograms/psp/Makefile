TARGET = attic_test
OBJS = main.o

CFLAGS = -O2 -Wall
LIBS = -lpspgum -lpspgu

EXTRA_TARGETS = EBOOT.PBP
PSP_EBOOT_TITLE = Attic Test (PSP)
# Without its own code the PSPSDK writes UCJS10041, which is a real game's.
SFOFLAGS = -s DISC_ID=ATTC00001

PSPSDK = $(shell psp-config --pspsdk-path)
include $(PSPSDK)/lib/build.mak
