/* display.c, X11 interface                                                 */

/* Copyright (C) 1996, MPEG Software Simulation Group. All Rights Reserved. */

/*
 * Disclaimer of Warranty
 *
 * These software programs are available to the user without any license fee or
 * royalty on an "as is" basis.  The MPEG Software Simulation Group disclaims
 * any and all warranties, whether express, implied, or statuary, including any
 * implied warranties or merchantability or of fitness for a particular
 * purpose.  In no event shall the copyright-holder be liable for any
 * incidental, punitive, or consequential damages of any kind whatsoever
 * arising from the use of these programs.
 *
 * This disclaimer of warranty extends to the user of these programs and user's
 * customers, employees, agents, transferees, successors, and assigns.
 *
 * The MPEG Software Simulation Group does not represent or warrant that the
 * programs furnished hereunder are free of infringement of any third-party
 * patents.
 *
 * Commercial implementations of MPEG-1 and MPEG-2 video, including shareware,
 * are subject to royalty fees to patent holders.  Many of these patents are
 * general enough such that they are unavoidable regardless of implementation
 * design.
 *
 */

#ifdef DISPLAY

 /* the Xlib interface is closely modeled after
  * mpeg_play 2.0 by the Berkeley Plateau Research Group
  */

#include <stdio.h>
#include <stdlib.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <string.h>

#include "config.h"
#include "global.h"

extern void conv422to444 _ANSI_ARGS_((unsigned char *src, unsigned char *dst));
extern void conv420to422 _ANSI_ARGS_((unsigned char *src, unsigned char *dst));
/* private prototypes */
static void Display_Image _ANSI_ARGS_((XImage * myximage, unsigned char *ImageData));

/* local data */
static unsigned char *ImageData, *ImageData2;

/* X11 related variables */
static Display *mydisplay;
static Window mywindow;
static GC mygc;
static XImage *myximage, *myximage2;
static int bpp;
static int has32bpp = 0;
static XWindowAttributes attribs;
static X_already_started = 0;


#ifdef SH_MEM

#include <sys/ipc.h>
#include <sys/shm.h>
#include <X11/extensions/XShm.h>

static int HandleXError _ANSI_ARGS_((Display * dpy, XErrorEvent * event));
static void InstallXErrorHandler _ANSI_ARGS_((void));
static void DeInstallXErrorHandler _ANSI_ARGS_((void));

static int Shmem_Flag;
static XShmSegmentInfo Shminfo1, Shminfo2;
static int gXErrorFlag;
static int CompletionType = -1;

static int HandleXError(Dpy, Event)
Display *Dpy;
XErrorEvent *Event;
{
    gXErrorFlag = 1;

    return 0;
}

static void InstallXErrorHandler()
{
    XSetErrorHandler(HandleXError);
    XFlush(mydisplay);
}

static void DeInstallXErrorHandler()
{
    XSetErrorHandler(NULL);
    XFlush(mydisplay);
}

#endif

/* Setup pseudocolor (grayscale) */
void set_colors()
{
	Colormap cmap;
	XColor mycolor[256];
	int i;
	if ((cmap = XCreateColormap(mydisplay, mywindow, attribs.visual,
		AllocAll)) == 0) {	/* allocate all colors */
		fprintf(stderr, "Can't get colors, using existing map\n");
		return;
	}
	for (i = 0; i < 256; i++) {
		mycolor[i].flags = DoRed | DoGreen | DoBlue;
		mycolor[i].pixel = i;
		mycolor[i].red = i << 8;
		mycolor[i].green = i << 8;
		mycolor[i].blue = i << 8;
	}
	XStoreColors(mydisplay, cmap, mycolor, 255);
	XSetWindowColormap(mydisplay, mywindow, cmap);
}
/* connect to server, create and map window,
 * allocate colors and (shared) memory
 */
void Initialize_Display_Process(name)
char *name;
{
    char dummy;
    int screen;
    unsigned int fg, bg;
    char *hello = "MPEG-2 Decoder";
    XSizeHints hint;
    XVisualInfo vinfo;
    XEvent xev;

    if (X_already_started)
	return;

    mydisplay = XOpenDisplay(name);

    if (mydisplay == NULL)
	Error("Can not open display\n");

    screen = DefaultScreen(mydisplay);

    hint.x = 200;
    hint.y = 200;
    hint.width = horizontal_size;
    hint.height = vertical_size;
    hint.flags = PPosition | PSize;

    /* Get some colors */

    bg = WhitePixel(mydisplay, screen);
    fg = BlackPixel(mydisplay, screen);

    /* Make the window */

    XGetWindowAttributes(mydisplay, DefaultRootWindow(mydisplay), &attribs);
    bpp = attribs.depth;
    if (bpp != 8 && bpp != 15 && bpp != 16 && bpp != 24 && bpp != 32)
	Error("Only 8,15,16,24, and 32bpp supported\n");
    mywindow = XCreateSimpleWindow(mydisplay, DefaultRootWindow(mydisplay),
		     hint.x, hint.y, hint.width, hint.height, 4, fg, bg);

    XSelectInput(mydisplay, mywindow, StructureNotifyMask);

    /* Tell other applications about this window */

    XSetStandardProperties(mydisplay, mywindow, hello, hello, None, NULL, 0, &hint);

    /* Map window. */

    XMapWindow(mydisplay, mywindow);

    /* Wait for map. */
    do {
	XNextEvent(mydisplay, &xev);
    }
    while (xev.type != MapNotify || xev.xmap.event != mywindow);
    if (bpp == 8)
	set_colors();

    XSelectInput(mydisplay, mywindow, NoEventMask);

    mygc = DefaultGC(mydisplay, screen);

#ifdef SH_MEM
    if (XShmQueryExtension(mydisplay))
	Shmem_Flag = 1;
    else {
	Shmem_Flag = 0;
	if (!Quiet_Flag)
	    fprintf(stderr, "Shared memory not supported\nReverting to normal Xlib\n");
    }

    if (Shmem_Flag)
	CompletionType = XShmGetEventBase(mydisplay) + ShmCompletion;

    InstallXErrorHandler();

    if (Shmem_Flag) {

	myximage = XShmCreateImage(mydisplay, None, bpp,
		ZPixmap, NULL, &Shminfo1, Coded_Picture_Width,
		Coded_Picture_Height);
	if (!progressive_sequence)
	    myximage2 = XShmCreateImage(mydisplay, None, bpp,
		ZPixmap, NULL, &Shminfo2, Coded_Picture_Width,
		Coded_Picture_Height);

	/* If no go, then revert to normal Xlib calls. */

	if (myximage == NULL || (!progressive_sequence && myximage2 == NULL)) {
	    if (myximage != NULL)
		XDestroyImage(myximage);
	    if (!progressive_sequence && myximage2 != NULL)
		XDestroyImage(myximage2);
	    if (!Quiet_Flag)
		fprintf(stderr, "Shared memory error, disabling (Ximage error)\n");
	    goto shmemerror;
	}
	/* Success here, continue. */

	Shminfo1.shmid = shmget(IPC_PRIVATE, 
			 myximage->bytes_per_line * myximage->height,
				IPC_CREAT | 0777);
	if (!progressive_sequence)
	    Shminfo2.shmid = shmget(IPC_PRIVATE, 
		       myximage2->bytes_per_line * myximage2->height,
				    IPC_CREAT | 0777);

	if (Shminfo1.shmid < 0 || (!progressive_sequence && Shminfo2.shmid < 0)) {
	    XDestroyImage(myximage);
	    if (!progressive_sequence)
		XDestroyImage(myximage2);
	    if (!Quiet_Flag)
		fprintf(stderr, "Shared memory error, disabling (seg id error)\n");
	    goto shmemerror;
	}
	Shminfo1.shmaddr = (char *) shmat(Shminfo1.shmid, 0, 0);
	Shminfo2.shmaddr = (char *) shmat(Shminfo2.shmid, 0, 0);

	if (Shminfo1.shmaddr == ((char *) -1) ||
	  (!progressive_sequence && Shminfo2.shmaddr == ((char *) -1))) {
	    XDestroyImage(myximage);
	    if (Shminfo1.shmaddr != ((char *) -1))
		shmdt(Shminfo1.shmaddr);
	    if (!progressive_sequence) {
		XDestroyImage(myximage2);
		if (Shminfo2.shmaddr != ((char *) -1))
		    shmdt(Shminfo2.shmaddr);
	    }
	    if (!Quiet_Flag) {
		fprintf(stderr, "Shared memory error, disabling (address error)\n");
	    }
	    goto shmemerror;
	}
	myximage->data = Shminfo1.shmaddr;
	ImageData = (unsigned char *) myximage->data;
	Shminfo1.readOnly = False;
	XShmAttach(mydisplay, &Shminfo1);
	if (!progressive_sequence) {
	    myximage2->data = Shminfo2.shmaddr;
	    ImageData2 = (unsigned char *) myximage2->data;
	    Shminfo2.readOnly = False;
	    XShmAttach(mydisplay, &Shminfo2);
	}
	XSync(mydisplay, False);

	if (gXErrorFlag) {
	    /* Ultimate failure here. */
	    XDestroyImage(myximage);
	    shmdt(Shminfo1.shmaddr);
	    if (!progressive_sequence) {
		XDestroyImage(myximage2);
		shmdt(Shminfo2.shmaddr);
	    }
	    if (!Quiet_Flag)
		fprintf(stderr, "Shared memory error, disabling.\n");
	    gXErrorFlag = 0;
	    goto shmemerror;
	} else {
	    shmctl(Shminfo1.shmid, IPC_RMID, 0);
	    if (!progressive_sequence)
		shmctl(Shminfo2.shmid, IPC_RMID, 0);
	}

	if (!Quiet_Flag) {
	    fprintf(stderr, "Sharing memory.\n");
	}
    } else {
      shmemerror:
	Shmem_Flag = 0;
#endif
	myximage = XGetImage(mydisplay, DefaultRootWindow(mydisplay), 0, 0,
	    Coded_Picture_Width, Coded_Picture_Height, AllPlanes, ZPixmap);
	ImageData = myximage->data;

	if (!progressive_sequence) {
	    myximage2 = XGetImage(mydisplay, DefaultRootWindow(mydisplay), 0,
		0, Coded_Picture_Width, Coded_Picture_Height,
		AllPlanes, ZPixmap);
	    ImageData2 = myximage2->data;
	}
#ifdef SH_MEM
    }

    DeInstallXErrorHandler();
#endif
    has32bpp = (myximage->bits_per_pixel > 24) ? 1 : 0;
    X_already_started++;
}

void Terminate_Display_Process()
{
    getchar();	/* wait for enter to remove window */
#ifdef SH_MEM
    if (Shmem_Flag) {
	XShmDetach(mydisplay, &Shminfo1);
	XDestroyImage(myximage);
	shmdt(Shminfo1.shmaddr);
	if (!progressive_sequence) {
	    XShmDetach(mydisplay, &Shminfo2);
	    XDestroyImage(myximage2);
	    shmdt(Shminfo2.shmaddr);
	}
    }
#endif
    XDestroyWindow(mydisplay, mywindow);
    XCloseDisplay(mydisplay);
    X_already_started = 0;
}

static void Display_Image(myximage, ImageData)
XImage *myximage;
unsigned char *ImageData;
{
#ifdef SH_MEM
    if (Shmem_Flag) {
	XShmPutImage(mydisplay, mywindow, mygc, myximage,
		0, 0, 0, 0, myximage->width, myximage->height, True);
	XFlush(mydisplay);

	while (1) {
	    XEvent xev;

	    XNextEvent(mydisplay, &xev);
	    if (xev.type == CompletionType)
		break;
	}
    } else
#endif
	XPutImage(mydisplay, mywindow, mygc, myximage, 0, 0,
		0, 0, myximage->width, myximage->height);
}

void Display_First_Field(void) { /* nothing */ }
void Display_Second_Field(void) { /* nothing */ }

do_display(unsigned char *src[])
{
    unsigned char *dst, *py, *pu, *pv;
    static unsigned char *u444 = 0, *v444, *u422, *v422;
    int x, y, Y, U, V, r, g, b, pixel;
    int crv, cbu, cgu, cgv;
    /* matrix coefficients */
    crv = Inverse_Table_6_9[matrix_coefficients][0];
    cbu = Inverse_Table_6_9[matrix_coefficients][1];
    cgu = Inverse_Table_6_9[matrix_coefficients][2];
    cgv = Inverse_Table_6_9[matrix_coefficients][3];
    py = src[0];
    dst = ImageData;
    if (bpp == 8) 	/* for speed on 8bpp we do grayscale */
	memcpy(dst, py, Coded_Picture_Height*Coded_Picture_Width);
    else {
	if (chroma_format==CHROMA444 || !hiQdither) {
		pv = src[1];
		pu = src[2];
	} else {
	    if (!u444) {
		if (!(u422=(unsigned char *)malloc((Coded_Picture_Width>>1)*
		    Coded_Picture_Height)))
		    Error("malloc failed");
		if (!(v422=(unsigned char *)malloc((Coded_Picture_Width>>1)*
		    Coded_Picture_Height)))
		    Error("malloc failed");
		if (!(u444=(unsigned char *)malloc(Coded_Picture_Width*
		    Coded_Picture_Height)))
		    Error("malloc failed");
		if (!(v444=(unsigned char *)malloc(Coded_Picture_Width*
		    Coded_Picture_Height)))
		    Error("malloc failed");
	    }
	    if (chroma_format==CHROMA420) {
		conv420to422(src[1],v422);
		conv420to422(src[2],u422);
		conv422to444(v422,v444);
		conv422to444(u422,u444);
	    } else {
		conv422to444(src[1],v444);
		conv422to444(src[2],u444);
	    }
	    pu = u444;
	    pv = v444;
	}
	for (y = 0; y < Coded_Picture_Height; y++) 
	    for (x = 0; x < Coded_Picture_Width; x++) {
		Y = 76309 * ((*py++) - 16);
		if (!hiQdither && chroma_format!=CHROMA444) {
		    if (chroma_format==CHROMA422)
			pixel = y * Chroma_Width + (x>>1);
		    else	/* 420 */
			pixel = (y>>1) * Chroma_Width + (x>>1);
		    U = pu[pixel] - 128;
		    V = pv[pixel] - 128;
		} else {
		    U = (*pu++) - 128;
		    V = (*pv++) - 128;
		}
		r = Clip[(Y+crv*V)>>16];
		g = Clip[(Y-cgu*U-cgv*V + 32768)>>16];
		b = Clip[(Y+cbu*U + 32768)>>16];
		if (has32bpp) {
			/* try to consolidate writes */
			pixel = (b<<16)|(g<<8)|r;
			*(unsigned int *)dst = pixel;
			dst+=4;
		} else if (bpp == 24) {
			*dst++ = r;
			*dst++ = g;
			*dst++ = b;
		} else {
			if (bpp > 15)	/* 16 bpp */
			    pixel=((b<<8)&63488)|((g<<3)&2016)|((r>>3)&31);
			else		/* 15 bpp */
			    pixel=((b<<7)&31744)|((g<<2)&992)|((r>>3)&31);
			*(unsigned short *)dst = pixel;
			dst+=2;
		}
	    }
    }
    Display_Image(myximage, ImageData);
}
#endif
