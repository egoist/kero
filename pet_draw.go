package main

import (
	"math"
	"time"

	"github.com/egoist/mygo/ui"

	"kero/internal/proto"
)

// --- the frog ---

// The frog's colors, which stay the same in either appearance: a mint
// frog on a desktop, not a UI.
var (
	petBody  = ui.Hex("#8ed6a4")
	petBelly = ui.Hex("#f7f1dc")
	petInk   = ui.Hex("#26362d")
	petCheek = ui.Hex("#f29b96")
	petLeaf  = ui.Hex("#5cae79")
	petSpark = ui.Hex("#f4c95d")
	petTear  = ui.Hex("#7bb8ea")
)

// petLook is where the frog is in its motion: offsets and expression.
type petLook struct {
	bob, sway, scan, blink, hop, shake, wave, sparkle, doze float32
	happy, sad, wink, wide, tap                             bool
}

// petLookAt works out the frog's pose for a mood, from the mood's start
// and the clock.
func (a *App) petLookAt(mood petMood, now time.Time) petLook {
	var l petLook
	l.wink = now.Sub(a.pet.wink) >= 0 && now.Sub(a.pet.wink) < petWink
	l.blink = petBlink(now, 0.9, 4.4)
	if l.wink {
		l.happy = true
	}
	if a.pet.calm {
		l.blink = petBlink(now, 1.3, 6)
		if mood == petAsleep {
			l.blink = 1
			l.doze = 1
		}
		l.wide = mood == petWaiting
		l.happy = l.happy || mood == petDone
		l.sad = mood == petFailed
		return l
	}
	t := float32(max(now.Sub(a.pet.since), 0).Seconds())
	switch mood {
	case petAsleep:
		d := float32(max(now.Sub(a.pet.lastActive.Add(petDoze)), 0).Seconds())
		l.doze = min(d/0.5, 1)
		l.bob = petWave(t, 5.2) * 1.2
		l.blink = 1
	case petWorking:
		l.bob = petWave(t, 1.5) * 2.2
		l.scan = petWave(t, 2.6) * 3.4
		l.blink = petBlink(now, 2.2, 3.2)
		l.tap = true
	case petWaiting:
		// A hop at the start of every 1.2 seconds.
		ph := float32(math.Mod(float64(t), 1.2) / 1.2)
		if ph < 0.5 {
			l.hop = float32(math.Sin(float64(ph)/0.5*math.Pi)) * 10
		}
		l.wave = 0.5 + 0.5*petWave(t, 0.6)
		l.wide = true
		l.blink = petBlink(now, 3.3, 5.5) * 0.35
		// Already answering it: it still waits, but stops insisting.
		if a.focused {
			if s := a.session(a.selected); s != nil && s.Status == proto.Waiting {
				l.hop *= 0.3
				l.wave *= 0.5
			}
		}
	case petDone:
		d := min(t, 1.4)
		l.hop = float32(math.Abs(float64(petWave(d/0.7, 1)))) * 12 * (1 - d/1.4)
		l.sparkle = min(t/0.25, 1)
		if t > 2.4 {
			l.sparkle *= max(0, 1-(t-2.4)/1.2)
		}
		l.happy = true
		l.blink = 1
	case petFailed:
		l.shake = float32(math.Sin(float64(t)*36)) * 3.6 * float32(math.Exp(float64(-t*2.2)))
		l.sad = true
		l.blink = 0
	default:
		l.bob = petWave(t, 3.6) * 1.6
		l.sway = petWave(t, 5.4) * 1.1
	}
	return l
}

// petDraw draws the frog into its box, hands on the window's edge.
func (a *App) petDraw(p *ui.Painter, r ui.Rect, mood petMood, hovered bool) {
	l := a.petLookAt(mood, p.Now())
	if hovered && mood == petAsleep && !a.pet.calm {
		l.blink = 0.35
		l.doze = 0.4
	}
	cx := r.X + r.W/2 + l.shake
	bottom := r.Y + r.H
	headY := bottom - 56 + l.bob - l.hop
	draw := func(fn func()) {
		p.Transform(ui.Scaling(petScale, petScale), cx, bottom, func() {
			if l.sway != 0 {
				p.Transform(ui.Rotation(l.sway), cx, bottom, fn)
				return
			}
			fn()
		})
	}
	draw(func() {
		// A soft shadow on the edge, and the arms behind the body.
		p.FillPath(petEllipse(cx, bottom-1.5, 42, 5), ui.RGBA(15, 25, 20, 0.13))
		lhx, lhy := cx-31, bottom-10.5
		rhx, rhy := cx+31, bottom-10.5
		rhand := float32(-14)
		switch {
		case mood == petWaiting:
			rhx = cx + 45
			rhy = bottom - 36 - 4*l.wave
			rhand = -24 - 18*l.wave
		case mood == petDone && p.Now().Sub(a.pet.since) < 1400*time.Millisecond:
			lhx, lhy = cx-43, bottom-31
			rhx, rhy = cx+43, bottom-31
		case mood == petWorking && l.tap:
			lhy = bottom - 10.5 - 3*float32(math.Abs(float64(petWave(float32(p.Now().Sub(a.pet.since).Seconds()), 0.5))))
		}
		p.Line(cx-30, headY+23, lhx, lhy-4, 9.5, petBody)
		p.Line(cx+30, headY+23, rhx, rhy-4, 9.5, petBody)

		// The eye bumps, then the head: a frog, not a ghost.
		p.FillPath(petEllipse(cx-22, headY-30, 15, 15), petBody)
		p.FillPath(petEllipse(cx+22, headY-30, 15, 15), petBody)
		p.FillPath(petHead(cx, headY, 88, 64), petBody)
		// A breath of light on the crown.
		p.Transform(ui.Rotation(-22), cx-19, headY-17, func() {
			p.FillPath(petEllipse(cx-19, headY-17, 13, 7.5), ui.RGBA(255, 255, 255, 0.16))
		})
		// The belly, cream and close to the edge.
		p.FillPath(petEllipse(cx, bottom-14, 24, 12.5), petBelly)

		petHand(p, lhx, lhy, 9.5, 0)
		petHand(p, rhx, rhy, 9.5, rhand)

		// The sprout: a stem and two leaves, which the frog's mood sways.
		sprout := -2 + 3*petWave(float32(p.Now().UnixMilli())/1000, 4.5)
		if mood == petWorking {
			sprout += 4 * petWave(float32(p.Now().UnixMilli())/1000, 1.6)
		}
		p.Line(cx, headY-31, cx+sprout, headY-44, 2.6, petLeaf)
		petLeafAt(p, cx+sprout, headY-44, 9, -35+3*l.sway, petLeaf)
		petLeafAt(p, cx+sprout-1, headY-41, 7, 145, petLeaf)

		// Eyes, cheeks and mouth.
		ex := cx + l.scan
		eyeY := headY - 32
		if l.happy {
			petEyeHappy(p, ex-22, eyeY)
			petEyeHappy(p, ex+22, eyeY)
		} else if l.blink > 0.72 {
			p.Line(ex-22-6, eyeY, ex-22+6, eyeY, 2.2, petInk)
			p.Line(ex+22-6, eyeY, ex+22+6, eyeY, 2.2, petInk)
		} else if l.sad {
			petEyeSad(p, ex-22, eyeY)
			petEyeSad(p, ex+22, eyeY)
		} else {
			petEyeOpen(p, ex-22, eyeY, l.blink, l.wide)
			petEyeOpen(p, ex+22, eyeY, l.blink, l.wide)
		}
		if l.wink {
			// The wink keeps the left eye open, and says so with a heart.
			p.FillPath(petEllipse(ex-22, eyeY, 7.2, 8.8), petInk)
			p.FillPath(petEllipse(ex-24.2, eyeY-2.6, 2.2, 2.6), ui.RGBA(255, 255, 255, 0.9))
			petHeart(p, cx+38, headY-40, 7*min(float32(p.Now().Sub(a.pet.wink).Seconds())/0.18, 1))
		}
		p.FillPath(petEllipse(cx-32, headY+9, 6.5, 3.2), petCheek.Alpha(0.55))
		p.FillPath(petEllipse(cx+32, headY+9, 6.5, 3.2), petCheek.Alpha(0.55))
		// Two nostrils, which make the face a frog's.
		p.FillPath(petEllipse(cx-4.5, headY+9, 1.1, 1.3), petInk.Alpha(0.45))
		p.FillPath(petEllipse(cx+4.5, headY+9, 1.1, 1.3), petInk.Alpha(0.45))
		petMouth(p, cx, headY+17, l)

		if l.sad {
			petDrop(p, cx+37, headY-12, 3.6)
		}
		if l.sparkle > 0 {
			ph := float32(p.Now().UnixMilli()%700) / 700
			petStar(p, cx-46, headY-30, 5.5*(0.6+0.4*ph), petSpark.Alpha(0.9-0.4*ph))
			petStar(p, cx+47, headY-16, 4.5*(0.6+0.4*(1-ph)), petSpark.Alpha(0.6+0.3*ph))
			petStar(p, cx+40, headY-46, 3.6*(0.5+0.5*ph), petSpark.Alpha(0.5+0.4*ph))
		}
		if l.doze > 0.2 {
			a.petZ(p, cx+38, headY-44, float32(p.Now().UnixMilli())/1000, l.doze)
		}
	})
}

// petHead is the frog's wide head, a rounded blob with a soft chin.
func petHead(cx, cy, w, h float32) *ui.Path {
	x0, x1 := cx-w/2, cx+w/2
	top, bot := cy-h/2, cy+h/2
	p := &ui.Path{}
	p.MoveTo(cx, top)
	p.CubeTo(cx+w*0.30, top, x1, cy-h*0.18, x1, cy+h*0.10)
	p.CubeTo(x1, cy+h*0.34, cx+w*0.28, bot, cx, bot)
	p.CubeTo(cx-w*0.28, bot, x0, cy+h*0.34, x0, cy+h*0.10)
	p.CubeTo(x0, cy-h*0.18, cx-w*0.30, top, cx, top)
	return p.Close()
}

// petEllipse is an ellipse as a path.
func petEllipse(cx, cy, rx, ry float32) *ui.Path {
	const k = 0.5522847498
	p := &ui.Path{}
	p.MoveTo(cx+rx, cy)
	p.CubeTo(cx+rx, cy+ry*k, cx+rx*k, cy+ry, cx, cy+ry)
	p.CubeTo(cx-rx*k, cy+ry, cx-rx, cy+ry*k, cx-rx, cy)
	p.CubeTo(cx-rx, cy-ry*k, cx-rx*k, cy-ry, cx, cy-ry)
	p.CubeTo(cx+rx*k, cy-ry, cx+rx, cy-ry*k, cx+rx, cy)
	return p.Close()
}

// petEyeOpen is an eye with a bright catch, which blink closes and wide
// opens.
func petEyeOpen(p *ui.Painter, x, y, blink float32, wide bool) {
	ry := 8.8 * (1 - blink*0.9)
	rx := float32(7.2)
	if wide {
		rx, ry = rx+0.8, ry+0.9
	}
	p.FillPath(petEllipse(x, y, rx, ry), petInk)
	p.FillPath(petEllipse(x-2.3, y-2.8, 2.2, 2.6), ui.RGBA(255, 255, 255, 0.92))
	p.FillPath(petEllipse(x+2.1, y+3.1, 0.9, 1.1), ui.RGBA(255, 255, 255, 0.45))
}

// petEyeHappy is a closed, smiling eye.
func petEyeHappy(p *ui.Painter, x, y float32) {
	eye := (&ui.Path{}).MoveTo(x-6, y+2).QuadTo(x, y-5, x+6, y+2)
	p.StrokePath(eye, 2.2, petInk)
}

// petEyeSad is a drooping eye.
func petEyeSad(p *ui.Painter, x, y float32) {
	eye := (&ui.Path{}).MoveTo(x-6, y-1).QuadTo(x, y+4, x+6, y+1)
	p.StrokePath(eye, 2.2, petInk)
	brow := (&ui.Path{}).MoveTo(x-5, y-8).LineTo(x+5, y-6)
	p.StrokePath(brow, 1.6, petInk.Alpha(0.55))
}

// petHand is a little mitten with two fingers, turned by angle.
func petHand(p *ui.Painter, x, y, r, angle float32) {
	p.Transform(ui.Rotation(angle), x, y+r, func() {
		p.FillPath(petEllipse(x, y, r, r*0.88), petBody)
		p.Line(x-r*0.36, y+1, x-r*0.36, y+r*0.54, 1.1, petInk.Alpha(0.16))
		p.Line(x+r*0.08, y+1, x+r*0.08, y+r*0.6, 1.1, petInk.Alpha(0.16))
	})
}

// petMouth is the frog's mouth, which its mood shapes.
func petMouth(p *ui.Painter, cx, y float32, l petLook) {
	switch {
	case l.wide:
		p.FillPath(petEllipse(cx, y+2, 4.2, 5.2), petInk)
	case l.sad:
		m := (&ui.Path{}).MoveTo(cx-6, y+3).QuadTo(cx, y-3, cx+6, y+3)
		p.StrokePath(m, 2, petInk)
	case l.happy:
		m := (&ui.Path{}).MoveTo(cx-8, y-1).QuadTo(cx, y+8, cx+8, y-1)
		p.StrokePath(m, 2, petInk)
	default:
		m := (&ui.Path{}).MoveTo(cx-6, y).QuadTo(cx, y+5, cx+6, y)
		p.StrokePath(m, 2, petInk)
	}
}

// petLeafAt is a leaf off a stem, at an angle.
func petLeafAt(p *ui.Painter, x, y, size, angle float32, c ui.Color) {
	p.Transform(ui.Rotation(angle), x, y, func() {
		leaf := (&ui.Path{}).MoveTo(x, y).
			QuadTo(x+size*0.55, y-size*0.8, x+size*1.35, y-size*0.18).
			QuadTo(x+size*0.55, y+size*0.42, x, y)
		p.FillPath(leaf.Close(), c)
	})
}

// petHeart is a small heart, for a pat.
func petHeart(p *ui.Painter, x, y, s float32) {
	if s <= 0 {
		return
	}
	h := (&ui.Path{}).
		MoveTo(x, y+s*0.85).
		CubeTo(x-s*1.3, y-s*0.1, x-s*0.55, y-s*1.15, x, y-s*0.4).
		CubeTo(x+s*0.55, y-s*1.15, x+s*1.3, y-s*0.1, x, y+s*0.85)
	p.FillPath(h.Close(), petCheek)
}

// petDrop is a sweat drop, for a failure.
func petDrop(p *ui.Painter, x, y, s float32) {
	d := (&ui.Path{}).MoveTo(x, y-s*1.4).
		QuadTo(x+s*1.1, y+s*0.2, x, y+s*0.8).
		QuadTo(x-s*1.1, y+s*0.2, x, y-s*1.4)
	p.FillPath(d.Close(), petTear)
}

// petStar is a four-point sparkle.
func petStar(p *ui.Painter, x, y, s float32, c ui.Color) {
	if s <= 0 {
		return
	}
	st := (&ui.Path{}).MoveTo(x, y-s).
		QuadTo(x+s*0.18, y-s*0.18, x+s, y).
		QuadTo(x+s*0.18, y+s*0.18, x, y+s).
		QuadTo(x-s*0.18, y+s*0.18, x-s, y).
		QuadTo(x-s*0.18, y-s*0.18, x, y-s)
	p.FillPath(st.Close(), c)
}

// petZ is a z, drifting up from a dozing frog.
func (a *App) petZ(p *ui.Painter, x, y, t, doze float32) {
	for i := 0; i < 3; i++ {
		ph := float32(math.Mod(float64(t*0.35+float32(i)/3), 1))
		size := 10 + 8*ph
		alpha := (1 - ph) * 0.7 * doze
		p.Text(x+ph*14, y-ph*30, "z", size, petInk.Alpha(alpha))
	}
}

// petBlink is how closed an eye is, blinking briefly every period
// seconds, its first blink offset by seed.
func petBlink(now time.Time, seed, period float64) float32 {
	t := math.Mod(float64(now.UnixNano())/1e9+seed, period)
	const d = 0.16
	if t < d {
		return float32(math.Sin(t / d * math.Pi))
	}
	return 0
}

// petWave is sine of period seconds.
func petWave(t, period float32) float32 {
	return float32(math.Sin(float64(t) / float64(period) * 2 * math.Pi))
}
