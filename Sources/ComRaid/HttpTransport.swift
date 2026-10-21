import Foundation

struct HttpRequest: Sendable {
  var method: String
  var path: String
  var headers: [String: String]
  var body: Data?
}

struct HttpResponse: Sendable {
  var statusCode: Int
  var body: Data
}

protocol HttpTransport: Sendable {
  func execute(_ request: HttpRequest) async throws -> HttpResponse
}

struct URLSessionHttpTransport: HttpTransport {
  let apiBaseURL: URL
  private let session: URLSession

  init(apiBaseURL: URL, session: URLSession = .shared) {
    self.apiBaseURL = apiBaseURL
    self.session = session
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    let base = apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: base + request.path) else {
      throw ComRaidError.apiError("Invalid URL for path \(request.path)")
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
    urlRequest.httpBody = request.body
    let (data, response) = try await session.data(for: urlRequest)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return HttpResponse(statusCode: status, body: data)
  }
}
