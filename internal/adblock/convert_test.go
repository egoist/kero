package adblock

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

// convert returns the rules of filters as JSON, a rule a line, in the
// order the lists have them.
func convert(filters ...string) (string, int) {
	var r Rules
	skipped := r.Convert(strings.Join(filters, "\n"))
	var lines []string
	for _, rule := range append(append(append(r.Block, r.Hide...), r.Except...), r.Important...) {
		b, _ := json.Marshal(rule)
		lines = append(lines, string(b))
	}
	return strings.Join(lines, "\n"), skipped
}

const subTypes = `"resource-type":["image","style-sheet","script","font","raw","svg-document","media","ping"]`

func TestConvertNetwork(t *testing.T) {
	tests := []struct {
		name, filter, want string
	}{
		{"domain", `||ads.example.com^`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[/:]"},"action":{"type":"block"}}`},
		{"domain and path", `||example.com/ads/*.js`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?example\\.com/ads/.*\\.js"},"action":{"type":"block"}}`},
		{"path", `/banner/*/img^`,
			`{"trigger":{"url-filter":"/banner/.*/img([^a-zA-Z0-9_.%-].*)?$",` + subTypes + `},"action":{"type":"block"}}`},
		{"separator inside", `-ad^300x250-`,
			`{"trigger":{"url-filter":"-ad[^a-zA-Z0-9_.%-]300x250-",` + subTypes + `},"action":{"type":"block"}}`},
		{"start and end", `|https://ads.example/x.js|`,
			`{"trigger":{"url-filter":"^https://ads\\.example/x\\.js$",` + subTypes + `},"action":{"type":"block"}}`},
		{"stars collapse", `/ad**s/x`,
			`{"trigger":{"url-filter":"/ad.*s/x",` + subTypes + `},"action":{"type":"block"}}`},
		{"specials escaped", `/a+b?c(d)[e]{f}\g$h`,
			`{"trigger":{"url-filter":"/a\\+b\\?c\\(d\\)\\[e\\]\\{f\\}\\\\g\\$h",` + subTypes + `},"action":{"type":"block"}}`},
		{"dollar in path", `/ad$id/x`,
			`{"trigger":{"url-filter":"/ad\\$id/x",` + subTypes + `},"action":{"type":"block"}}`},
		{"third-party", `||tracker.example^$third-party`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?tracker\\.example[/:]","load-type":["third-party"]},"action":{"type":"block"}}`},
		{"not third-party", `/pixel.gif$~third-party`,
			`{"trigger":{"url-filter":"/pixel\\.gif",` + subTypes + `,"load-type":["first-party"]},"action":{"type":"block"}}`},
		{"1p", `/pixel.gif$1p`,
			`{"trigger":{"url-filter":"/pixel\\.gif",` + subTypes + `,"load-type":["first-party"]},"action":{"type":"block"}}`},
		{"types", `/track.$script,image,xmlhttprequest`,
			`{"trigger":{"url-filter":"/track\\.","resource-type":["image","raw","script"]},"action":{"type":"block"}}`},
		{"stylesheet font media", `/x.$stylesheet,font,media`,
			`{"trigger":{"url-filter":"/x\\.","resource-type":["font","media","style-sheet"]},"action":{"type":"block"}}`},
		{"websocket ping object other", `/x.$websocket,ping,object,other`,
			`{"trigger":{"url-filter":"/x\\.","resource-type":["ping","raw"]},"action":{"type":"block"}}`},
		{"subdocument", `||ads.example^$subdocument`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?ads\\.example[/:]","resource-type":["document"],"load-context":["child-frame"]},"action":{"type":"block"}}`},
		{"subdocument and script", `||ads.example^$subdocument,script`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?ads\\.example[/:]","resource-type":["document","script"]},"action":{"type":"block"}}`},
		{"popup", `||pop.example^$popup`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?pop\\.example[/:]","resource-type":["popup"]},"action":{"type":"block"}}`},
		{"not types", `/x.$~script,~image`,
			`{"trigger":{"url-filter":"/x\\.","resource-type":["font","media","ping","raw","style-sheet","svg-document"]},"action":{"type":"block"}}`},
		{"types and not types", `/x.$script,image,~image`,
			`{"trigger":{"url-filter":"/x\\.","resource-type":["script"]},"action":{"type":"block"}}`},
		{"domain option", `/ad.js$domain=news.example|Blog.example`,
			`{"trigger":{"url-filter":"/ad\\.js","if-domain":["*news.example","*blog.example"],` + subTypes + `},"action":{"type":"block"}}`},
		{"not domain option", `/ad.js$domain=~shop.example`,
			`{"trigger":{"url-filter":"/ad\\.js","unless-domain":["*shop.example"],` + subTypes + `},"action":{"type":"block"}}`},
		{"domains win over exclusions", `/ad.js$domain=news.example|~sub.news.example`,
			`{"trigger":{"url-filter":"/ad\\.js","if-domain":["*news.example"],` + subTypes + `},"action":{"type":"block"}}`},
		{"match-case", `/AdBanner.$match-case`,
			`{"trigger":{"url-filter":"/AdBanner\\.","url-filter-is-case-sensitive":true,` + subTypes + `},"action":{"type":"block"}}`},
		{"no pattern", `$script,third-party,domain=news.example`,
			`{"trigger":{"url-filter":".*","if-domain":["*news.example"],"resource-type":["script"],"load-type":["third-party"]},"action":{"type":"block"}}`},
		{"document", `||scam.example^$document`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?scam\\.example[/:]","resource-type":["document"]},"action":{"type":"block"}}`},
		{"exception", `@@||cdn.example^$script`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?cdn\\.example[/:]","resource-type":["script"]},"action":{"type":"ignore-previous-rules"}}`},
		{"page exception", `@@||shop.example^$document`,
			`{"trigger":{"url-filter":".*","if-domain":["*shop.example"]},"action":{"type":"ignore-previous-rules"}}`},
		{"page exception of a path", `@@|https://shop.example/checkout$document`,
			`{"trigger":{"url-filter":".*","if-top-url":["^https://shop\\.example/checkout"]},"action":{"type":"ignore-previous-rules"}}`},
		{"hiding exception", `@@||shop.example^$elemhide`,
			`{"trigger":{"url-filter":".*","if-domain":["*shop.example"],"resource-type":["document"]},"action":{"type":"ignore-previous-rules"}}`},
		{"generic hiding exception", `@@||shop.example^$generichide`,
			`{"trigger":{"url-filter":".*","if-domain":["*shop.example"],"resource-type":["document"]},"action":{"type":"ignore-previous-rules"}}`},
		{"important", `||ads.example^$important`,
			`{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?ads\\.example[/:]"},"action":{"type":"block"}}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, skipped := convert(tt.filter)
			if skipped != 0 || got != tt.want {
				t.Errorf("%s:\n got %s (%d skipped)\nwant %s", tt.filter, got, skipped, tt.want)
			}
		})
	}
}

func TestConvertSkips(t *testing.T) {
	for _, filter := range []string{
		`||ads.example^$redirect=noopjs`,
		`||ads.example^$csp=script-src 'none'`,
		`||ads.example^$removeparam=utm_source`,
		`||ads.example^$replace=/a/b/`,
		`/^https?:\/\/ads\./`,
		`||ads.example^$domain=example.*`,
		`||ädverts.example^`,
		`||*`,
		`||^`,
		`example.com##+js(abort-on-property-read, x)`,
		`example.com##.ad:has-text(Sponsored)`,
		`example.com##div:-abp-contains(Ad)`,
		`example.com#?#.ad:upward(2)`,
		`example.com#$#.ad { display: none }`,
		`example.com#%#window.x = 1`,
		`example.com##^script:has-text(ad)`,
		`example.*##.ad`,
		`##.ad { color: red }`,
		`||ads.example^$popunder`,
	} {
		if got, skipped := convert(filter); skipped != 1 || got != "" {
			t.Errorf("%s made %s", filter, got)
		}
	}
	// Comments and headers are no filters.
	if got, skipped := convert("[Adblock Plus 2.0]", "! Title: EasyList", "", "  "); skipped != 0 || got != "" {
		t.Errorf("comments made %q, %d skipped", got, skipped)
	}
}

func TestConvertHiding(t *testing.T) {
	tests := []struct {
		name    string
		filters []string
		want    string
	}{
		{"generic, grouped", []string{`##.ad`, `###banner`, `##a[href^="https://ads.example/"]`},
			`{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad, #banner, a[href^=\"https://ads.example/\"]"}}`},
		{"pseudo-class alone", []string{`##.ad`, `##div:not(.x)`, `##.promo`},
			`{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".ad, .promo"}}` + "\n" +
				`{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"div:not(.x)"}}`},
		{"domains", []string{`news.example,blog.example##.sponsored`, `blog.example,news.example##.promo`},
			`{"trigger":{"url-filter":".*","if-domain":["*blog.example","*news.example"]},"action":{"type":"css-display-none","selector":".sponsored, .promo"}}`},
		{"domains win over exclusions", []string{`news.example,~sub.news.example##.ad`},
			`{"trigger":{"url-filter":".*","if-domain":["*news.example"]},"action":{"type":"css-display-none","selector":".ad"}}`},
		{"exclusions only", []string{`~shop.example##.ad`},
			`{"trigger":{"url-filter":".*","unless-domain":["*shop.example"]},"action":{"type":"css-display-none","selector":".ad"}}`},
		{"exception of a domain", []string{`##.ad`, `##.promo`, `shop.example#@#.ad`},
			`{"trigger":{"url-filter":".*","unless-domain":["*shop.example"]},"action":{"type":"css-display-none","selector":".ad"}}` + "\n" +
				`{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".promo"}}`},
		{"exception everywhere", []string{`##.ad`, `news.example##.ad`, `#@#.ad`, `##.promo`},
			`{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".promo"}}`},
		{"exception of a domain's", []string{`news.example,blog.example##.ad`, `news.example#@#.ad`},
			`{"trigger":{"url-filter":".*","if-domain":["*blog.example"]},"action":{"type":"css-display-none","selector":".ad"}}`},
		{"entities dropped", []string{`news.example,google.*##.ad`},
			`{"trigger":{"url-filter":".*","if-domain":["*news.example"]},"action":{"type":"css-display-none","selector":".ad"}}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got, skipped := convert(tt.filters...); skipped != 0 || got != tt.want {
				t.Errorf("%v:\n got %s (%d skipped)\nwant %s", tt.filters, got, skipped, tt.want)
			}
		})
	}
}

// Rules come in the order WebKit must see them: blocks, hides, the
// exceptions that undo them, and what blocks despite exceptions.
func TestConvertOrder(t *testing.T) {
	var r Rules
	r.Convert("@@||cdn.example^$script\n||ads.example^$important\n##.ad\n||cdn.example^")
	if len(r.Block) != 1 || len(r.Hide) != 1 || len(r.Except) != 1 || len(r.Important) != 1 || r.Len() != 4 {
		t.Fatalf("rules = %+v", r)
	}
	lists := r.Lists()
	var rules []Rule
	if len(lists) != 1 || json.Unmarshal([]byte(lists[0]), &rules) != nil {
		t.Fatalf("lists = %v", lists)
	}
	var order []string
	for _, rule := range rules {
		order = append(order, rule.Action.Type)
	}
	if strings.Join(order, " ") != "block css-display-none ignore-previous-rules block" {
		t.Errorf("order = %v", order)
	}
}

func TestLists(t *testing.T) {
	var r Rules
	for i := range MaxRules + 10 {
		r.Block = append(r.Block, Rule{Trigger: Trigger{URLFilter: "/" + strconv.Itoa(i)}, Action: Action{Type: "block"}})
	}
	r.Except = []Rule{{Trigger: Trigger{URLFilter: "x"}, Action: Action{Type: "ignore-previous-rules"}}}
	lists := r.Lists()
	if len(lists) != 2 {
		t.Fatalf("%d lists", len(lists))
	}
	total := 0
	for _, l := range lists {
		var rules []Rule
		if err := json.Unmarshal([]byte(l), &rules); err != nil {
			t.Fatal(err)
		}
		if len(rules) > MaxRules || rules[len(rules)-1].Action.Type != "ignore-previous-rules" {
			t.Errorf("a list of %d rules ends with %v", len(rules), rules[len(rules)-1])
		}
		total += len(rules) - 1
	}
	if total != MaxRules+10 {
		t.Errorf("the lists block with %d rules, want %d", total, MaxRules+10)
	}
	// Filter lists overlap: a rule is there once.
	var twice Rules
	twice.Convert("||ads.example^\n##.ad")
	twice.Convert("||ads.example^\n##.ad")
	if lists := twice.Lists(); len(lists) != 1 || strings.Count(lists[0], `"trigger"`) != 2 {
		t.Errorf("the same filters twice make %v", lists)
	}
	var empty Rules
	if lists := empty.Lists(); len(lists) != 0 {
		t.Errorf("no rules make %v", lists)
	}
}
