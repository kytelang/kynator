// A foreign (non-Kyte) Go HTTP server: reads $PORT and echoes it plus the FOO env var.
// Build: CGO_ENABLED=0 go build -o app main.go   (see ../build.sh) -- a fully static binary.
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	foo := os.Getenv("FOO")
	if foo == "" {
		foo = "(unset)"
	}
	fmt.Fprintf(os.Stderr, "foreign Go server listening on PORT=%s FOO=%s\n", port, foo)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "GO-OK port=%s FOO=%s\n", port, foo)
	})
	http.ListenAndServe(":"+port, nil)
}
