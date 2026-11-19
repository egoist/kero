package cli

import (
	"fmt"

	"kero/internal/defterm"
)

// defaultTerminalCmd says which app runs the scripts opened with it,
// makes Kero that app, or puts Terminal.app back: the macOS
// LaunchServices' answer, which the app's Settings window shows too.
func defaultTerminalCmd(args []string) error {
	f, err := parse(args, nil, nil)
	if err != nil {
		return err
	}
	sub := "status"
	if len(f.pos) > 0 {
		sub = f.pos[0]
	}
	switch sub {
	case "status":
		path, err := defterm.Status()
		if err != nil {
			return err
		}
		if path == "" {
			fmt.Println("no default terminal for shell scripts")
			return nil
		}
		fmt.Println(path)
		return nil
	case "set":
		if err := defterm.Set(); err != nil {
			return err
		}
		fmt.Println("Kero is the default terminal for shell scripts")
		return nil
	case "restore":
		if err := defterm.Restore(); err != nil {
			return err
		}
		fmt.Println("Terminal.app is the default terminal for shell scripts")
		return nil
	}
	return usageErr("kero default-terminal takes status, set or restore")
}
