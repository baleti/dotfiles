package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"
)

// rpc sends one JSON request to the running daemon and returns its reply.
func rpc(req map[string]any) (map[string]any, error) {
	c, err := net.DialTimeout("unix", sockPath, 2*time.Second)
	if err != nil {
		return nil, fmt.Errorf("daemon not running (%v); start it with: systemctl --user start wa", err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(90 * time.Second))
	if err := json.NewEncoder(c).Encode(req); err != nil {
		return nil, err
	}
	var res map[string]any
	if err := json.NewDecoder(c).Decode(&res); err != nil {
		return nil, err
	}
	if e, ok := res["error"].(string); ok && e != "" {
		return nil, fmt.Errorf("%s", e)
	}
	return res, nil
}

func listenRPC(handle func(map[string]any) (map[string]any, error)) (net.Listener, error) {
	_ = os.Remove(sockPath)
	l, err := net.Listen("unix", sockPath)
	if err != nil {
		return nil, err
	}
	_ = os.Chmod(sockPath, 0o600)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				c.SetDeadline(time.Now().Add(90 * time.Second))
				var req map[string]any
				if json.NewDecoder(c).Decode(&req) != nil {
					return
				}
				res, err := handle(req)
				if err != nil {
					res = map[string]any{"error": err.Error()}
				}
				json.NewEncoder(c).Encode(res)
			}(c)
		}
	}()
	return l, nil
}
