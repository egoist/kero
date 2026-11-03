package cli

import (
	"slices"
	"strconv"
	"strings"

	"kero/internal/client"
	"kero/internal/proto"
)

const moveUsage = "kero projects move <project> <position|top|bottom|up|down>"

// moveProject moves a project to another place in the order the app's
// sidebar lists them in, which kerod keeps.
func moveProject(c *client.Client, st proto.State, args []string) error {
	if len(args) != 2 {
		return usageErr(moveUsage)
	}
	id, err := findProject(st, args[0])
	if err != nil {
		return err
	}
	from := slices.IndexFunc(st.Projects, func(p proto.Project) bool { return p.ID == id })
	to, err := moveIndex(from, len(st.Projects), args[1])
	if err != nil {
		return err
	}
	return c.Call("project.move", proto.MoveProjectParams{ID: id, Index: to}, nil)
}

// moveIndex is the index a project at from goes to, of n, by where: a
// position from 1 for the top, or top, bottom, up or down. Past either end
// is that end.
func moveIndex(from, n int, where string) (int, error) {
	to := 0
	switch strings.ToLower(where) {
	case "top", "first":
		to = 0
	case "bottom", "last":
		to = n - 1
	case "up":
		to = from - 1
	case "down":
		to = from + 1
	default:
		pos, err := strconv.Atoi(where)
		if err != nil || pos < 1 {
			return 0, usageErr("%s: %q is no position (1 is the top)", moveUsage, where)
		}
		to = pos - 1
	}
	return max(0, min(to, n-1)), nil
}
