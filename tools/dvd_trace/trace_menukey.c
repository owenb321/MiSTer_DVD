/* Replicate "Menu key during playback": boot (auto-plays to the feature), then
 * once we're in the feature title, call dvdnav_menu_call(Root) and see whether
 * libdvdnav parks on the still menu (correct) or bounces back to the title. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dvdnav/dvdnav.h"
#include "dvdnav/dvd_types.h"

int main(int argc, char **argv) {
  dvdnav_t *nav;
  uint8_t mem[DVD_VIDEO_LB_LEN];
  int finished = 0, cells = 0, blocks = 0, menu_called = 0;
  int which = (argc > 2) ? atoi(argv[2]) : 3;   /* 2=Title, 3=Root */
  if (argc < 2) { printf("usage: %s <iso> [menuid 2=Title 3=Root]\n", argv[0]); return 1; }
  if (dvdnav_open(&nav, argv[1]) != DVDNAV_STATUS_OK) { printf("open failed\n"); return 2; }
  dvdnav_set_readahead_flag(nav, 0);

  while (!finished) {
    int event, len;
    uint8_t *buf = mem;
    if (dvdnav_get_next_block(nav, buf, &event, &len) == DVDNAV_STATUS_ERR) {
      printf("BLOCK ERR: %s\n", dvdnav_err_to_string(nav)); break;
    }
    switch (event) {
    case DVDNAV_BLOCK_OK:
      if (++blocks > 300000) finished = 1;
      break;
    case DVDNAV_STILL_FRAME: {
      dvdnav_still_event_t *s = (dvdnav_still_event_t *)buf;
      int32_t tt = 0, ptt = 0; dvdnav_current_title_info(nav, &tt, &ptt);
      if (s->length == 0xff) {
        printf("\n>>>>> PARKED on INDEFINITE STILL. Title=%d Chapter=%d  menu_called=%d\n",
               tt, ptt, menu_called);
        finished = 1;
      } else { printf("[skip %ds still]\n", s->length); dvdnav_still_skip(nav); }
      break; }
    case DVDNAV_WAIT: dvdnav_wait_skip(nav); break;
    case DVDNAV_CELL_CHANGE: {
      int32_t tt = 0, ptt = 0; dvdnav_current_title_info(nav, &tt, &ptt);
      printf("[CELL #%d] Title=%d Chapter=%d\n", ++cells, tt, ptt);
      /* Once we're solidly in the feature (title 11), fire the Menu key ONCE. */
      if (!menu_called && tt >= 10) {
        printf("\n########## CALLING dvdnav_menu_call(%s) ##########\n",
               which == 2 ? "Title" : "Root");
        if (dvdnav_menu_call(nav, which) != DVDNAV_STATUS_OK)
          printf("  menu_call FAILED: %s\n", dvdnav_err_to_string(nav));
        menu_called = 1;
      }
      if (cells > 60) finished = 1;
      break; }
    case DVDNAV_HIGHLIGHT: {
      dvdnav_highlight_event_t *h = (dvdnav_highlight_event_t *)buf;
      printf("[HIGHLIGHT button %d]\n", h->buttonN); break; }
    case DVDNAV_VTS_CHANGE: printf("[VTS_CHANGE]\n"); break;
    case DVDNAV_STOP: printf("[STOP]\n"); finished = 1; break;
    default: break;
    }
  }
  dvdnav_close(nav);
  return 0;
}
