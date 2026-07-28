# z386 MiSTer Verilator harness

## Live control socket

Start the simulator with a localhost TCP control socket:

```sh
./obj_dir/Vz386_mister_sim --disk ../../sdcard/win311_auto.vhd --control-port 9386
```

Send a single command with `simctl.py`:

```sh
./simctl.py status
./simctl.py mouse -20 -40 0
./simctl.py key enter
./simctl.py screenshot /tmp/z386.png
./simctl.py checkpoint
```

With no command arguments, `simctl.py` keeps one connection open and streams
commands from stdin. This preserves the ordering of mouse motion, button, and
keyboard packets:

```sh
printf '%s\n' \
  'mouse 0 0 1' \
  'mouse 10 -4 1' \
  'mouse 10 -4 1' \
  'mouse 0 0 0' | ./simctl.py
```

Commands are:

```text
mouse <dx> <dy> [buttons]
key <name> [press|down|up]
checkpoint
screenshot [path]
status
quit
```

PS/2 mouse Y is positive upward and negative downward. Mouse button bits are
left=1, right=2, and middle=4. The server binds to `127.0.0.1` by default; use
`--control-bind 0.0.0.0` only when control from another machine is intended.
