package cli

import (
	"errors"
	"testing"
)

func TestMoveIndex(t *testing.T) {
	for _, tc := range []struct {
		from, n int
		where   string
		want    int
	}{
		{2, 4, "top", 0},
		{0, 4, "bottom", 3},
		{0, 4, "Last", 3},
		{2, 4, "up", 1},
		{0, 4, "up", 0},
		{2, 4, "down", 3},
		{3, 4, "down", 3},
		{3, 4, "1", 0},
		{0, 4, "3", 2},
		{0, 4, "99", 3},
	} {
		got, err := moveIndex(tc.from, tc.n, tc.where)
		if err != nil || got != tc.want {
			t.Errorf("from %d of %d, %q: %d, %v; want %d", tc.from, tc.n, tc.where, got, err, tc.want)
		}
	}
	for _, where := range []string{"0", "-1", "middle", ""} {
		if _, err := moveIndex(1, 4, where); !errors.Is(err, errUsage) {
			t.Errorf("%q: %v, want a usage error", where, err)
		}
	}
}
