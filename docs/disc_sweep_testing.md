Harry Potter Interactive DVD Game testing:
- Boot goes to the correct spot
- Menu goes back to the main menu selection
- From the main menu, selecting "Play Game" brings you to a Player Mode screen with 'Single Player' and 'Multi-Player' options but no highlight. The debug overlay does show the highlight areas and pressing select here does select the option and move on. If I skip the transition video before this screen by pressing select, then I do get the correct highlight to show up.
- On several occasions, skipping menus transitions lead to the correct screen screen (static image) being pixelated but it looked normal after a few seconds.
- There is a score card screen you can access during the game that flashes on screen for about 2 seconds before returning and I think this is supposed to last longer.

WEAKEST_LINK_DES testing (2026-08-25 round — the answer-reveal / banked-money flash is
diagnosed and fixed on branch `fix/cell-duration-frames`; see docs/disc_sweep.md Round-7):
- Selecting an answer flashes the correct/wrong reveal in <1 s (should be ~2 s), and the
  banked-money screen after Bank does the same; questions hold correctly.

WEAKEST_LINK_DES testing:
- Game loads to menu fine
- Selecting single player plays a long intro to the game then when it lookslike it's about to ask a question, it cuts to a screen that displays 'Round winnings' of 7500 GBP but select or direction buttons do not work on this screen. Menu button does return to the player selection menu.
- Multiplayer works similarly, once it reaches a question it cuts to that round winnings screen (debug overlay shows CH 92/2)

