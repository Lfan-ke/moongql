///|
/// The HTTP surface: a GraphiQL IDE page plus the `POST /graphql` endpoint,
/// wired as a `moonasgi` handler so moongql plugs straight into `mooncat` (or any
/// server that binds the ASGI seam). A `GET` on the endpoint serves the IDE; a
/// `POST` reads a `{ query, variables, operationName }` body, runs it through the
/// executor, and replies with the `{ data, errors }` JSON. Everything rides the
/// synchronous `run_http_app` core moonasgi exposes, so the whole thing is
/// testable on every backend through `TestClient` without an async runtime.

///|
/// The GraphiQL IDE page, wired to fetch against `endpoint`. This is the same
/// standalone GraphiQL build strawberry serves: React and GraphiQL load from a
/// CDN via an import map, and a fetcher points at the GraphQL endpoint. Splitting
/// the template around the endpoint keeps it a plain string with no interpolation
/// machinery.
pub fn graphiql_html(endpoint? : String = "/graphql") -> String {
  graphiql_head() + endpoint + graphiql_tail()
}

///|
/// Everything in the GraphiQL page up to the fetcher URL literal.
fn graphiql_head() -> String {
  let head =
    #|<!DOCTYPE html>
    #|<html lang="en">
    #|<head>
    #|  <meta charset="utf-8" />
    #|  <title>GraphiQL</title>
    #|  <meta name="viewport" content="width=device-width, initial-scale=1" />
    #|  <style>
    #|    body { margin: 0; }
    #|    #graphiql { height: 100dvh; }
    #|    .loading { height: 100dvh; display: flex; align-items: center; justify-content: center; font-family: sans-serif; }
    #|  </style>
    #|  <link rel="stylesheet" href="https://esm.sh/graphiql@3/dist/style.css" />
    #|  <script type="importmap">
    #|    {
    #|      "imports": {
    #|        "react": "https://esm.sh/react@18",
    #|        "react/jsx-runtime": "https://esm.sh/react@18/jsx-runtime",
    #|        "react-dom": "https://esm.sh/react-dom@18",
    #|        "react-dom/client": "https://esm.sh/react-dom@18/client",
    #|        "graphiql": "https://esm.sh/graphiql@3?standalone&external=react,react-dom",
    #|        "@graphiql/toolkit": "https://esm.sh/@graphiql/toolkit?standalone&external=graphql"
    #|      }
    #|    }
    #|  </script>
    #|</head>
    #|<body>
    #|  <div id="graphiql"><div class="loading">Loading GraphiQL…</div></div>
    #|  <script type="module">
    #|    import React from 'react';
    #|    import ReactDOM from 'react-dom/client';
    #|    import { GraphiQL } from 'graphiql';
    #|    import { createGraphiQLFetcher } from '@graphiql/toolkit';
    #|    const fetcher = createGraphiQLFetcher({ url: '
  head
}

///|
/// Everything in the GraphiQL page after the fetcher URL literal.
fn graphiql_tail() -> String {
  let tail =
    #|' });
    #|    const root = ReactDOM.createRoot(document.getElementById('graphiql'));
    #|    root.render(React.createElement(GraphiQL, { fetcher }));
    #|  </script>
    #|</body>
    #|</html>
  tail
}

///|
/// An `application/json` error reply carrying a single `errors` entry, for the
/// transport-level failures (wrong path, wrong method, unreadable body) that stop
/// a request before the executor runs.
fn error_response(status : Int, message : String) -> @moonasgi.Response {
  let errs : Array[Json] = [jobj([("message", message.to_json())])]
  @moonasgi.Response::json(status~, jobj([("errors", errs.to_json())]))
}

///|
/// Pull `query`, `variables` and `operationName` out of a parsed request body.
/// A missing or non-string `query` yields `None`; `variables` defaults to empty
/// and `operationName` to `None`, matching the GraphQL-over-HTTP request shape.
fn parse_request(body : Json) -> (String?, Map[String, Json], String?) {
  match body {
    Object(m) => {
      let query = match m.get("query") {
        Some(String(q)) => Some(q)
        _ => None
      }
      let variables = match m.get("variables") {
        Some(Object(v)) => v
        _ => Map([])
      }
      let operation_name = match m.get("operationName") {
        Some(String(n)) => Some(n)
        _ => None
      }
      (query, variables, operation_name)
    }
    _ => (None, Map([]), None)
  }
}

///|
/// Build the moonasgi request handler for a schema and its resolvers. A `GET` on
/// `path` serves the GraphiQL IDE (when `graphiql` is true); a `POST` on `path`
/// executes a GraphQL request and returns `{ data, errors }`. Any other path is a
/// `404` and any other method a `405`, both as JSON errors. Lift it onto an
/// `AsgiApp` with `graphql_app`, or drive it directly with moonasgi's
/// `TestClient`.
pub fn graphql_handler(
  schema : Schema,
  resolvers : Resolvers,
  path? : String = "/graphql",
  graphiql? : Bool = true,
) -> @moonasgi.Handler {
  fn(req : @moonasgi.Request) -> @moonasgi.Response {
    if req.path != path {
      return error_response(404, "Not Found")
    }
    match req.http_method {
      "GET" | "HEAD" =>
        if graphiql {
          @moonasgi.Response::new(
            200,
            [("content-type", "text/html; charset=utf-8")],
            @utf8.encode(graphiql_html(endpoint=path)),
          )
        } else {
          error_response(405, "Method Not Allowed")
        }
      "POST" => {
        let body = @json.parse(@utf8.decode_lossy(req.body[:])) catch {
          _ => return error_response(400, "Request body is not valid JSON")
        }
        let (query, variables, operation_name) = parse_request(body)
        match query {
          None => error_response(400, "No GraphQL query found in request body")
          Some(q) =>
            @moonasgi.Response::json(
              execute(schema, resolvers, q, variables~, operation_name~),
            )
        }
      }
      _ => error_response(405, "Method Not Allowed")
    }
  }
}

///|
/// Lift the GraphQL handler onto the load-bearing `AsgiApp` a server binds to.
/// This is what `mooncat` (or any moonasgi server) mounts to serve the schema
/// over real HTTP; the request→response logic is shared with `graphql_handler`,
/// which `TestClient` exercises without a socket.
pub fn graphql_app(
  schema : Schema,
  resolvers : Resolvers,
  path? : String = "/graphql",
  graphiql? : Bool = true,
) -> @moonasgi.AsgiApp {
  @moonasgi.to_asgi(graphql_handler(schema, resolvers, path~, graphiql~))
}
