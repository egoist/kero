//go:build !darwin

package daemon

func checkProjectDir(string) error { return nil }
