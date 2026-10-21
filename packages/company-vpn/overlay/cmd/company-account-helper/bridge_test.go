package main

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
)

func testBridge(input string) *bridge {
	return &bridge{input: bufio.NewScanner(strings.NewReader(input)), output: json.NewEncoder(io.Discard)}
}
