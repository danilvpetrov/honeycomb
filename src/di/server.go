package di

import (
	"os"

	"github.com/icecave/honeycomb/src/backend"
	"github.com/icecave/honeycomb/src/frontend"
	"github.com/icecave/honeycomb/src/frontend/health"
	"github.com/icecave/honeycomb/src/proxy"
)

// Server returns a new front-end server.
func (con *Container) Server() *frontend.Server {
	return con.get(
		"server",
		func() (interface{}, error) {
			logger := con.Logger()
			return &frontend.Server{
				BindAddress:         con.BindAddress(),
				Locator:             con.Locator(),
				CertificateProvider: con.CertificateProvider(),
				HTTPProxy:           proxy.NewHTTPProxy(logger),
				WebSocketProxy:      proxy.NewWebSocketProxy(logger),
				Interceptor:         &health.Interceptor{},
				Logger:              logger,
				Metrics: &frontend.StatsDMetrics{
					Client: con.StatsDClient(),
				},
			}, nil
		},
		nil,
	).(*frontend.Server)
}

// BindAddress returns the address that the server should listen on.
func (con *Container) BindAddress() string {
	port := os.Getenv("PORT")
	if port == "" {
		return ":8443"
	}
	return ":" + port
}

// Locator returns the back-end locator used to resolve server names to endpoints.
func (con *Container) Locator() backend.Locator {
	return con.get(
		"server.locator",
		func() (interface{}, error) {
			staticLocator := &backend.StaticLocator{}
			staticLocator.Add("static.192.168.60.36.xip.io", &backend.Endpoint{
				Description: "local-echo-server",
				Address:     "localhost:8080",
			})

			return backend.AggregateLocator{
				staticLocator,
				con.DockerLocator(),
			}, nil
		},
		nil,
	).(backend.Locator)
}

// HealthChecker returns the health-checker that is to be used to query the
// server's health.
func (con *Container) HealthChecker() health.Checker {
	return con.get(
		"docker.health-checker",
		func() (interface{}, error) {
			return &health.Client{Address: con.BindAddress()}, nil
		},
		nil,
	).(health.Checker)
}
