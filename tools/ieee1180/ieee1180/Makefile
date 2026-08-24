# Makefile for ieeetest

CC = cc
CFLAGS	= -O

INCS	= dct.h
SRCS	= ieeetest.c jrevdct.c
OBJS	= ieeetest.o jrevdct.o
LIBS	= -lm
PROG	= ieeetest
OTHER   = doieee jrevdct.out

RM	= /bin/rm -f

all:	$(PROG)

world:	clean all

ieeetest:	ieeetest.o jrevdct.o
	$(CC) $(CFLAGS) -o ieeetest ieeetest.o jrevdct.o $(LIBS)

clean:
	$(RM) $(PROG) $(OBJS)

distribute:
	$(RM) test1180.tar test1180.tar.Z
	tar cvf test1180.tar README Makefile $(SRCS) $(INCS) $(OTHER)
	compress -v test1180.tar

ieeetest.o: ieeetest.c dct.h
jrevdct.o: jrevdct.c dct.h
