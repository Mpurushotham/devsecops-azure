// =============================================================================
// payments-api — .NET 10 minimal API
// =============================================================================
// The reference workload for this platform, and the target shape of the
// .NET Framework migration (docs/MIGRATION-DOTNET.md). It demonstrates the
// four things every service on this platform must do:
//
//   1. Authenticate to Azure with workload identity — no connection strings
//   2. Emit OpenTelemetry traces, metrics and structured logs to the collector
//   3. Expose /healthz (liveness) and /readyz (readiness) separately
//   4. Set security headers and shut down gracefully on SIGTERM
// =============================================================================

using Azure.Identity;
using Microsoft.Data.SqlClient;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

var serviceName = builder.Configuration["OTEL_SERVICE_NAME"] ?? "payments-api";
var serviceVersion = builder.Configuration["APP_VERSION"] ?? "dev";

// ── OpenTelemetry ───────────────────────────────────────────────────────────
// Everything goes to the in-cluster collector over OTLP. The collector — not
// the app — decides what is sampled and where it is forwarded, so changing the
// observability backend never requires redeploying a service.
var resource = ResourceBuilder.CreateDefault()
    .AddService(serviceName, serviceVersion: serviceVersion)
    .AddAttributes(new KeyValuePair<string, object>[]
    {
        new("deployment.environment", builder.Configuration["ENVIRONMENT"] ?? "unknown"),
        new("k8s.pod.name", Environment.GetEnvironmentVariable("POD_NAME") ?? "unknown"),
        new("k8s.namespace.name", Environment.GetEnvironmentVariable("POD_NAMESPACE") ?? "unknown"),
    });

builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .SetResourceBuilder(resource)
        .AddAspNetCoreInstrumentation(o =>
        {
            // Probe traffic is constant and diagnostically worthless; tracing it
            // would dominate the sample budget.
            o.Filter = ctx => !ctx.Request.Path.StartsWithSegments("/healthz")
                           && !ctx.Request.Path.StartsWithSegments("/readyz")
                           && !ctx.Request.Path.StartsWithSegments("/metrics");
            o.RecordException = true;
        })
        .AddHttpClientInstrumentation()
        .AddSqlClientInstrumentation(o => o.SetDbStatementForText = false) // never log SQL text: it carries PII
        .AddOtlpExporter())
    .WithMetrics(metrics => metrics
        .SetResourceBuilder(resource)
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddPrometheusExporter());

builder.Logging.AddOpenTelemetry(o =>
{
    o.SetResourceBuilder(resource);
    o.IncludeFormattedMessage = true;
    o.IncludeScopes = true;
    o.AddOtlpExporter();
});

// ── Data access ─────────────────────────────────────────────────────────────
// DefaultAzureCredential picks up the workload identity token projected into
// the pod. There is no password in configuration, in Key Vault, or in the
// connection string — the identity IS the credential.
builder.Services.AddSingleton<SqlConnectionFactory>(_ =>
    new SqlConnectionFactory(
        builder.Configuration.GetConnectionString("Default")
            ?? throw new InvalidOperationException("ConnectionStrings__Default is required"),
        new DefaultAzureCredential()));

builder.Services.AddHealthChecks()
    .AddCheck<DatabaseHealthCheck>("database", tags: new[] { "ready" });

// Behind the ingress controller, so the client IP arrives in X-Forwarded-For.
builder.Services.Configure<Microsoft.AspNetCore.HttpOverrides.ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedFor
                             | Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

var app = builder.Build();

app.UseForwardedHeaders();

// ── Security headers ────────────────────────────────────────────────────────
app.Use(async (context, next) =>
{
    var headers = context.Response.Headers;
    headers["X-Content-Type-Options"] = "nosniff";
    headers["X-Frame-Options"] = "DENY";
    headers["Content-Security-Policy"] = "default-src 'self'";
    headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
    headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains";
    // Kestrel's banner discloses the framework version to anyone scanning.
    headers.Remove("Server");
    await next();
});

// ── Endpoints ───────────────────────────────────────────────────────────────
// Liveness must not touch dependencies: if the database is down, restarting
// this pod does not help and the restart loop makes the outage worse.
app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }))
   .ExcludeFromDescription();

// Readiness does check dependencies: an instance that cannot reach the database
// should be pulled out of the load balancer rotation without being killed.
app.MapHealthChecks("/readyz", new Microsoft.AspNetCore.Diagnostics.HealthChecks.HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready")
});

app.MapPrometheusScrapingEndpoint("/metrics");

app.MapGet("/api/v1/info", (IConfiguration cfg) => Results.Ok(new
{
    service = serviceName,
    version = serviceVersion,
    environment = cfg["ENVIRONMENT"] ?? "unknown",
    runtime = Environment.Version.ToString()
}));

app.MapGet("/api/v1/payments/{id:guid}", async (Guid id, SqlConnectionFactory factory, CancellationToken ct) =>
{
    await using var connection = await factory.OpenAsync(ct);
    await using var command = connection.CreateCommand();

    // Parameterised — never string-concatenated. The Semgrep rule
    // sql-injection-format-string in security/semgrep/.semgrep.yml blocks the
    // alternative at PR time.
    command.CommandText = "SELECT TOP 1 Id, Amount, Currency, Status FROM dbo.Payments WHERE Id = @id";
    command.Parameters.Add(new SqlParameter("@id", System.Data.SqlDbType.UniqueIdentifier) { Value = id });

    await using var reader = await command.ExecuteReaderAsync(ct);
    if (!await reader.ReadAsync(ct))
    {
        return Results.NotFound();
    }

    return Results.Ok(new
    {
        id = reader.GetGuid(0),
        amount = reader.GetDecimal(1),
        currency = reader.GetString(2),
        status = reader.GetString(3)
    });
});

// ── Graceful shutdown ───────────────────────────────────────────────────────
// Kubernetes removes the pod from Endpoints and sends SIGTERM concurrently.
// Sleeping first lets in-flight kube-proxy updates settle, so no request is
// routed to a terminating pod — this is what makes a rolling deploy invisible.
app.Lifetime.ApplicationStopping.Register(() =>
{
    var drainSeconds = int.TryParse(Environment.GetEnvironmentVariable("SHUTDOWN_DRAIN_SECONDS"), out var s) ? s : 5;
    Thread.Sleep(TimeSpan.FromSeconds(drainSeconds));
});

app.Run();

// Exposed so the integration tests can drive the app through WebApplicationFactory.
public partial class Program { }
