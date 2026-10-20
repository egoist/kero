module kero

go 1.27.1

tool github.com/egoist/mygo/cmd/mygo

require (
	github.com/BurntSushi/toml v1.6.0
	github.com/ebitengine/purego v0.11.1
	github.com/egoist/mygo v0.5.6-0.20261020115920-163d50e2acc1
	golang.org/x/sys v0.49.0
	golang.org/x/term v0.47.0
)

require (
	github.com/go-text/typesetting v0.3.5 // indirect
	golang.org/x/image v0.46.0 // indirect
	golang.org/x/text v0.43.0 // indirect
)

replace github.com/egoist/mygo => github.com/mrzzmrzz/mygo v0.5.6-0.20261020160456-82a91545178d
