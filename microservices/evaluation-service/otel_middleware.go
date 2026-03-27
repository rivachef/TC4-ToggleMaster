package main

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
	"go.opentelemetry.io/otel/trace"
)

var (
	tracer          trace.Tracer
	requestCounter  metric.Int64Counter
	requestDuration metric.Float64Histogram
)

func initOtelMetrics(serviceName string) {
	tracer = otel.Tracer(serviceName)

	meter := otel.Meter(serviceName)

	var err error
	requestCounter, err = meter.Int64Counter(
		"http_server_request_total",
		metric.WithDescription("Total number of HTTP requests"),
	)
	if err != nil {
		panic(err)
	}

	requestDuration, err = meter.Float64Histogram(
		"http_server_request_duration_seconds",
		metric.WithDescription("HTTP request duration in seconds"),
		metric.WithUnit("s"),
	)
	if err != nil {
		panic(err)
	}
}

// otelMiddleware wraps an http.Handler with OpenTelemetry tracing and metrics.
func otelMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))

		spanName := fmt.Sprintf("%s %s", r.Method, r.URL.Path)
		ctx, span := tracer.Start(ctx, spanName,
			trace.WithSpanKind(trace.SpanKindServer),
			trace.WithAttributes(
				semconv.HTTPMethod(r.Method),
				semconv.HTTPTarget(r.URL.Path),
				attribute.String("http.route", r.URL.Path),
			),
		)
		defer span.End()

		rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		start := time.Now()
		next.ServeHTTP(rw, r.WithContext(ctx))
		duration := time.Since(start).Seconds()

		span.SetAttributes(semconv.HTTPStatusCode(rw.statusCode))

		attrs := metric.WithAttributes(
			attribute.String("http.method", r.Method),
			attribute.String("http.route", r.URL.Path),
			attribute.Int("http.response.status_code", rw.statusCode),
			attribute.String("service.name", "evaluation-service"),
		)
		requestCounter.Add(ctx, 1, attrs)
		requestDuration.Record(ctx, duration, attrs)
	})
}

// propagateContext injects OTel context into outgoing HTTP requests.
func propagateContext(ctx context.Context, req *http.Request) {
	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
