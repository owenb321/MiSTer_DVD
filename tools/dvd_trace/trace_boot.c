/* Non-interactive boot tracer: feed blocks, skip WAIT + FINITE stills, and STOP
 * at the first INDEFINITE (0xFF) still (= the menu a real player parks on).
 * Prints the domain/PGC/cell path (plus libdvdnav TRACE VM output). */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include "dvdnav/dvdnav.h"

int main(int argc, char **argv) {
  dvdnav_t *nav;
  uint8_t mem[DVD_VIDEO_LB_LEN];
  int finished = 0, cells = 0, blocks = 0;
  if (argc < 2) { printf("usage: %s <iso>\n", argv[0]); return 1; }
  if (dvdnav_open(&nav, argv[1]) != DVDNAV_STATUS_OK) { printf("open failed\n"); return 2; }
  dvdnav_set_readahead_flag(nav, 0);
  dvdnav_set_PGC_positioning_flag(nav, 1);

  while (!finished) {
    int event, len;
    uint8_t *buf = mem;
    if (dvdnav_get_next_block(nav, buf, &event, &len) == DVDNAV_STATUS_ERR) {
      printf("BLOCK ERR: %s\n", dvdnav_err_to_string(nav)); break;
    }
    switch (event) {
    case DVDNAV_BLOCK_OK:
      if (++blocks > 200000) { printf("TOO MANY BLOCKS -> giving up\n"); finished = 1; }
      break;
    case DVDNAV_STILL_FRAME: {
      dvdnav_still_event_t *s = (dvdnav_still_event_t *)buf;
      int32_t tt = 0, ptt = 0;
      dvdnav_current_title_info(nav, &tt, &ptt);
      if (s->length == 0xff) {
        printf("\n>>>>> PARKED on INDEFINITE STILL after %d cells, %d blocks."
               " Title=%d Chapter=%d  <-- this is where a real player HOLDS (the menu)\n",
               cells, blocks, tt, ptt);
        finished = 1;
      } else {
        printf("[skip %d s finite still]\n", s->length);
        dvdnav_still_skip(nav);
      }
      break; }
    case DVDNAV_WAIT:
      dvdnav_wait_skip(nav); break;
    case DVDNAV_CELL_CHANGE: {
      int32_t tt = 0, ptt = 0;
      dvdnav_current_title_info(nav, &tt, &ptt);
      printf("[CELL_CHANGE #%d] Title=%d Chapter=%d\n", ++cells, tt, ptt);
      if (cells > 400) { printf("TOO MANY CELLS -> giving up\n"); finished = 1; }
      break; }
    case DVDNAV_HIGHLIGHT: {
      dvdnav_highlight_event_t *h = (dvdnav_highlight_event_t *)buf;
      printf("[HIGHLIGHT button %d]\n", h->buttonN); break; }
    case DVDNAV_VTS_CHANGE:
      printf("[VTS_CHANGE]\n"); break;
    case DVDNAV_STOP:
      printf("[STOP]\n"); finished = 1; break;
    default: break;
    }
  }
  dvdnav_close(nav);
  return 0;
}
