// Package templates renders plain-text notifications.
package templates

import (
	"fmt"
	"strings"
	"text/template"
)

/*
Block comment with code-looking content:
	func fake() string { return "not code" }
	`not a raw string`
*/

const usage = `Usage: notify [flags] <recipient>

Flags:
  -subject string   subject line ("quotes" are literal here)
  -dry-run          print instead of sending // not a comment
  /* also not a comment */
`

const pathPattern = `^/users/(\d+)/inbox$`

var greeting = template.Must(template.New("greeting").Parse(`Hello {{.Name}},
You have {{len .Messages}} new message(s).
{{range .Messages}}- {{.Subject}}
{{end}}`))

// Message is one notification.
type Message struct {
	Subject string `json:"subject"`
	Body    string `json:"body,omitempty"`
}

// Recipient receives messages.
type Recipient struct {
	Name     string
	Messages []Message
}

// Render executes the greeting template.
func (r *Recipient) Render() (string, error) {
	var sb strings.Builder
	if err := greeting.Execute(&sb, r); err != nil {
		return "", fmt.Errorf("render %q: %w", r.Name, err)
	}
	return sb.String(), nil
}

// Ratio divides twice; nothing here is a comment or regex.
func Ratio(a, b float64) float64 {
	return a / b / 2
}

func quoteRune() rune { return '"' }

func escaped() string {
	return "tab\tquote\"slash/* not a comment */"
}

func main() {
	r := &Recipient{Name: "Ada", Messages: []Message{{Subject: "hi"}, {Subject: `raw "subject"`}}}
	out, err := r.Render()
	if err != nil {
		panic(err)
	}
	fmt.Println(out, usage, pathPattern, Ratio(9, 3), string(quoteRune()), escaped())
}
