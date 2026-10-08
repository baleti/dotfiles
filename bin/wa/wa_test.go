package main

import "testing"

func TestSelftest(t *testing.T) {
	if err := selftest(); err != nil {
		t.Fatal(err)
	}
}
