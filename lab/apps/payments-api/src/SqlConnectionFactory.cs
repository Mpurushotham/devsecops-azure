using Azure.Core;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Diagnostics.HealthChecks;

/// <summary>
/// Opens SQL connections authenticated by the pod's workload identity.
/// </summary>
/// <remarks>
/// Tokens are cached until shortly before expiry rather than fetched per
/// connection: the IMDS endpoint is rate limited, and a cold token fetch on
/// every request adds latency to the hot path during a traffic spike.
/// </remarks>
public sealed class SqlConnectionFactory
{
    private static readonly string[] Scopes = { "https://database.windows.net/.default" };
    private static readonly TimeSpan RefreshMargin = TimeSpan.FromMinutes(5);

    private readonly string _connectionString;
    private readonly TokenCredential _credential;
    private readonly SemaphoreSlim _tokenLock = new(1, 1);

    private AccessToken _token;

    public SqlConnectionFactory(string connectionString, TokenCredential credential)
    {
        _connectionString = connectionString;
        _credential = credential;
    }

    public async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var connection = new SqlConnection(_connectionString)
        {
            AccessToken = await GetTokenAsync(ct)
        };

        try
        {
            await connection.OpenAsync(ct);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private async Task<string> GetTokenAsync(CancellationToken ct)
    {
        if (_token.ExpiresOn > DateTimeOffset.UtcNow.Add(RefreshMargin))
        {
            return _token.Token;
        }

        await _tokenLock.WaitAsync(ct);
        try
        {
            // Re-check: another request may have refreshed while we waited.
            if (_token.ExpiresOn <= DateTimeOffset.UtcNow.Add(RefreshMargin))
            {
                _token = await _credential.GetTokenAsync(new TokenRequestContext(Scopes), ct);
            }

            return _token.Token;
        }
        finally
        {
            _tokenLock.Release();
        }
    }
}

/// <summary>
/// Readiness probe dependency check. Deliberately not wired to liveness:
/// restarting the pod cannot fix a database outage, and a restart storm during
/// one turns a degradation into a full outage.
/// </summary>
public sealed class DatabaseHealthCheck : IHealthCheck
{
    private readonly SqlConnectionFactory _factory;

    public DatabaseHealthCheck(SqlConnectionFactory factory) => _factory = factory;

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));

            await using var connection = await _factory.OpenAsync(timeout.Token);
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT 1";
            await command.ExecuteScalarAsync(timeout.Token);

            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("Database unreachable", ex);
        }
    }
}
