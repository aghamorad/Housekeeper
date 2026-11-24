# Housekeeper 0.33.0

**Fix Permissions is gone.** The Permissions Doctor rewrote ownership across root-owned
dotfiles, config folders and launch agents — the biggest blast radius in the app, and the
job that damaged this Mac the first time it ran. It is deleted from the codebase and from
every way in: dashboard, sidebar, quick jump, job list, window title, and the menu
notification it used to answer.

**The icon fills its square.** The glass-tile artwork had transparent margins, and macOS 26
renders icons like that on its own light plate at about 80% scale — that plate was the box.
The artwork is now full-bleed, so the system's rounded-square mask is the only edge left.

Nothing else in the app changed.
