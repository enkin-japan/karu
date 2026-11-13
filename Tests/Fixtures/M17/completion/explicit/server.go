package server

type Server struct {
	Addr string
	Port int
}

func (s *Server) Start() error { return nil }
func (s *Server) Stop()        {}

type Conn struct {
	ID     int
	Remote string
}

func (c *Conn) Close() error { return nil }

func run() {
	var srv Server
	srv⟨1⟩
}

func handle(c *Conn) {
	c⟨2⟩
}
