# Demo ROM

`Demo.gb` is the game the Apple TV app plays when there is no phone paired
yet. It comes from `Scripts/cassowary/make-demo-rom.py`:

```bash
python3 Scripts/cassowary/make-demo-rom.py Cassowary/Resources/TV/Demo.gb
```

It is a 32 KB Game Boy ROM that draws a patterned background and lets you
move a ball with the d-pad. It is our own test fixture, not a game, and it is
generated — regenerate it with the command above rather than editing the
binary.
