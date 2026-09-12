// A foreign ASP.NET Core Web API, built with Native AOT (see aspnetaot.csproj). The AOT-friendly
// slim builder serves a single endpoint that echoes the port and FOO. ASP.NET Core reads its port from
// the ASPNETCORE_HTTP_PORTS environment variable, which is what the manifest's portEnv points at.
var builder = WebApplication.CreateSlimBuilder(args);
var app = builder.Build();
app.MapGet("/", () => {
    var port = Environment.GetEnvironmentVariable("ASPNETCORE_HTTP_PORTS") ?? "?";
    var foo  = Environment.GetEnvironmentVariable("FOO") ?? "(unset)";
    return $"DOTNET-OK port={port} FOO={foo}\n";
});
app.Run();
