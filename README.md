# Implode
Adds an ability proc glow to the Cooldown Manager icon and actionbar icon of Implosion and plays an alert sound when the spell is both off cooldown and the addon's estimate of your Wild Imps number is 6 or more.

- The Blizzard API no longer allows addons to directly track the number of Wild Imps while in combat, so the addon must use an estimate.
- The estimated number is based on Inner Demons 12s spawns, Hand of Gul'dan casts, Ruination casts, Implosion casts, and the natural decay of imps while in or out of combat.
- The estimate is not perfect, so check the real number displayed on the Implosion ability and make the final decision yourself before sending it.
