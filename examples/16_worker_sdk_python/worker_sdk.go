// Thin Go port of the Autonomic EffectSocket frame transport.
package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
)

func roundTrip(path string, req any) (map[string]any, error) {
	c, e := net.Dial("unix", path)
	if e != nil {
		return nil, e
	}
	defer c.Close()
	b, e := json.Marshal(req)
	if e != nil {
		return nil, e
	}
	if len(b) == 0 || len(b) > 1048576 {
		return nil, fmt.Errorf("frame out of bounds")
	}
	h := make([]byte, 4)
	binary.BigEndian.PutUint32(h, uint32(len(b)))
	if _, e = c.Write(append(h, b...)); e != nil {
		return nil, e
	}
	if _, e = io.ReadFull(c, h); e != nil {
		return nil, e
	}
	n := binary.BigEndian.Uint32(h)
	if n == 0 || n > 1048576 {
		return nil, fmt.Errorf("bad response frame")
	}
	out := make([]byte, n)
	if _, e = io.ReadFull(c, out); e != nil {
		return nil, e
	}
	var v map[string]any
	e = json.Unmarshal(out, &v)
	return v, e
}
func main() {
	if len(os.Args) == 1 {
		fmt.Println("worker_sdk.go: transport source present; pass a socket path in your integration harness")
	}
}
