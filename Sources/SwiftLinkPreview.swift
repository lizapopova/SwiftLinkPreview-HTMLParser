//
//  SwiftLinkPreview.swift
//  SwiftLinkPreview
//
//  Created by Leonardo Cardoso on 09/06/2016.
//  Copyright © 2016 leocardz.com. All rights reserved.
//
import Foundation
import Fuzi
import os.log

public enum SwiftLinkResponseKey: String {
    case url
    case finalUrl
    case canonicalUrl
    case title
    case description
    case image
    case images
    case icon
}

open class Cancellable: NSObject {
    public private(set) var isCancelled: Bool = false

    open func cancel() {
        isCancelled = true
    }
}

open class SwiftLinkPreview: NSObject {
    
    public typealias Response = [SwiftLinkResponseKey: Any]

    // MARK: - Vars
    static let titleMinimumRelevant: Int = 15
    static let decriptionMinimumRelevant: Int = 100

    public var session: URLSession
    public let workQueue: DispatchQueue
    public let responseQueue: DispatchQueue
    public let cache: Cache

    public static let defaultWorkQueue = DispatchQueue.global(qos: .userInitiated)

    // MARK: - Constructor
    
    //Swift-only init with default parameters
    @nonobjc public init(session: URLSession = URLSession.shared, workQueue: DispatchQueue = SwiftLinkPreview.defaultWorkQueue, responseQueue: DispatchQueue = DispatchQueue.main, cache: Cache = DisabledCache.instance) {
        self.workQueue = workQueue
        self.responseQueue = responseQueue
        self.cache = cache
        self.session = session
    }
    
    //Objective-C init with default parameters
    @objc public override init() {
        let _session = URLSession.shared
        let _workQueue: DispatchQueue = SwiftLinkPreview.defaultWorkQueue
        let _responseQueue: DispatchQueue = DispatchQueue.main
        let _cache: Cache  = DisabledCache.instance
        
        self.workQueue = _workQueue
        self.responseQueue = _responseQueue
        self.cache = _cache
        self.session = _session
    }

    //Objective-C init with paramaters.  nil objects will default.  Timeout values are ignored if InMemoryCache is disabled.
    @objc public init(session: URLSession?, workQueue: DispatchQueue?, responseQueue: DispatchQueue? , disableInMemoryCache: Bool, cacheInvalidationTimeout: TimeInterval, cacheCleanupInterval: TimeInterval) {
        
        let _session = session ?? URLSession.shared
        let _workQueue = workQueue ?? SwiftLinkPreview.defaultWorkQueue
        let _responseQueue = responseQueue ?? DispatchQueue.main
        let _cache: Cache  = disableInMemoryCache ? DisabledCache.instance : InMemoryCache(invalidationTimeout: cacheInvalidationTimeout, cleanupInterval: cacheCleanupInterval)

        self.workQueue = _workQueue
        self.responseQueue = _responseQueue
        self.cache = _cache
        self.session = _session
    }
    
    
    // MARK: - Functions
    // Make preview
    //Swift-only preview function using Swift specific closure types
    @nonobjc @discardableResult open func preview(_ text: String, onSuccess: @escaping (Response) -> Void, onError: @escaping (PreviewError) -> Void) -> Cancellable {
        
        let cancellable = Cancellable()

        self.session = URLSession(configuration: self.session.configuration,
                                  delegate: self, // To handle redirects
            delegateQueue: self.session.delegateQueue)
        
        let successResponseQueue = { (response: Response) in
            if !cancellable.isCancelled {
                self.responseQueue.async {
                    if !cancellable.isCancelled {
                        onSuccess(response)
                    }
                }
            }
        }

        let errorResponseQueue = { (error: PreviewError) in
            if !cancellable.isCancelled {
                self.responseQueue.async {
                    if !cancellable.isCancelled {
                        onError(error)
                    }
                }
            }
        }

        if let url = self.extractURL(text: text) {
            workQueue.async {
                if cancellable.isCancelled {return}

                if let result = self.cache.slp_getCachedResponse(url: url.absoluteString) {
                    successResponseQueue(result)
                } else {

                    self.unshortenURL(url, cancellable: cancellable, completion: { unshortened in
                        if let result = self.cache.slp_getCachedResponse(url: unshortened.absoluteString) {
                            successResponseQueue(result)
                        } else {

                            var result: [SwiftLinkResponseKey: Any] = [:]
                            result[.url] = url
                            result[.finalUrl] = self.extractInURLRedirectionIfNeeded(unshortened)
                            result[.canonicalUrl] = self.extractCanonicalURL(unshortened)

                            self.extractInfo(response: result, cancellable: cancellable, completion: {

                                result[.title] = $0[.title]
                                result[.description] = $0[.description]
                                result[.image] = $0[.image]
                                result[.images] = $0[.images]
                                result[.icon] = $0[.icon]

                                self.cache.slp_setCachedResponse(url: unshortened.absoluteString, response: result)
                                self.cache.slp_setCachedResponse(url: url.absoluteString, response: result)

                                successResponseQueue(result)
                            }, onError: errorResponseQueue)
                        }
                    }, onError: errorResponseQueue)
                }
            }
        } else {
            onError(.noURLHasBeenFound(text))
        }

        return cancellable
    }

    /*
     Extract url redirection inside the GET query.
     Like https://www.dji.com/404?url=http%3A%2F%2Fwww.dji.com%2Fmatrice600-pro%2Finfo#specs -> http://www.dji.com/de/matrice600-pro/info#specs
     */
    private func extractInURLRedirectionIfNeeded(_ url: URL) -> URL {
        var url = url
        var absoluteString = url.absoluteString + "&id=12"

        if let range = absoluteString.range(of: "url="),
            let lastChar = absoluteString.last,
            let lastCharIndex = absoluteString.range(of: String(lastChar), options: .backwards, range: nil, locale: nil) {
            absoluteString = String(absoluteString[range.upperBound ..< lastCharIndex.upperBound])

            if let range = absoluteString.range(of: "&"),
                let firstChar = absoluteString.first,
                let firstCharIndex = absoluteString.index(of: firstChar) {
                absoluteString = String(absoluteString[firstCharIndex ..< absoluteString.index(before: range.upperBound)])

                if let decoded = absoluteString.removingPercentEncoding, let newURL = URL(string: decoded) {
                    url = newURL
                }
            }

        }

        return url
    }
    
    //Objective-C wrapper for preview method.  Core incompataility is use of Swift specific enum types in closures.
    //Returns a dictionary of rsults rather than enum for success, and an NSError object on error that encodes the local error description on error
    /*
     Keys for the dictionary are derived from the enum names above.  That enum def is canonical, below is a convenience comment
     url
     finalUrl
     canonicalUrl
     title
     description
     image
     images
     icon
     
     */
    @objc @discardableResult open func previewLink(_ text: String, onSuccess: @escaping (Dictionary<String, Any>) -> Void, onError: @escaping (NSError) -> Void) -> Cancellable {
        
        func success (_ result: Response) -> Void {
            var ResponseData = [String: Any]()
            for item in result {
                ResponseData.updateValue(item.value, forKey: item.key.rawValue)
            }
            onSuccess(ResponseData)
        }
        
        
        func failure (_ theError: PreviewError) -> Void  {
            var errorCode: Int
            errorCode = 1
            
            switch theError {
            case .noURLHasBeenFound:
                errorCode = 1
            case .invalidURL:
                errorCode = 2
            case .cannotBeOpened:
                errorCode = 3
            case .parseError:
                errorCode = 4
            }
            
            onError(NSError(domain: "SwiftLinkPreviewDomain",
                            code: errorCode,
                            userInfo: [NSLocalizedDescriptionKey: theError.description]))
        }
        
        return self.preview(text, onSuccess: success, onError: failure)
    }
}

// Extraction functions
extension SwiftLinkPreview {

    // Extract first URL from text
    open func extractURL(text: String) -> URL? {
        do {
            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(location: 0, length: text.utf16.count)
            let matches = detector.matches(in: text, options: [], range: range)

            return matches.compactMap { $0.url }.first
        } catch {
            return nil
        }
    }

    // Unshorten URL by following redirections
    fileprivate func unshortenURL(_ url: URL, cancellable: Cancellable, completion: @escaping (URL) -> Void, onError: @escaping (PreviewError) -> Void) {

        if cancellable.isCancelled {return}

        var task: URLSessionDataTask?
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        task = session.dataTask(with: request, completionHandler: { data, response, error in
            if error != nil {
                self.workQueue.async {
                    if !cancellable.isCancelled {
                        onError(.cannotBeOpened("\(url.absoluteString): \(error.debugDescription)"))
                    }
                }
                task = nil
            } else {
                if let finalResult = response?.url {
                    if (finalResult.absoluteString == url.absoluteString) {
                        self.workQueue.async {
                            if !cancellable.isCancelled {
                                completion(url)
                            }
                        }
                        task = nil
                    } else {
                        task?.cancel()
                        task = nil
                        self.unshortenURL(finalResult, cancellable: cancellable, completion: completion, onError: onError)
                    }
                } else {
                    self.workQueue.async {
                        if !cancellable.isCancelled {
                            completion(url)
                        }
                    }
                    task = nil
                }
            }
        })

        if let task = task {
            task.resume()
        } else {
            self.workQueue.async {
                if !cancellable.isCancelled {
                    onError(.cannotBeOpened(url.absoluteString))
                }
            }
        }
    }

    // Extract HTML code and the information contained on it
    fileprivate func extractInfo(response: Response, cancellable: Cancellable, completion: @escaping (Response) -> Void, onError: (PreviewError) -> ()) {

        guard !cancellable.isCancelled, let url = response[.finalUrl] as? URL else { return }

        if url.absoluteString.isImage() {
            var result = response

            result[.title] = ""
            result[.description] = ""
            result[.images] = [url.absoluteString]
            result[.image] = url.absoluteString

            completion(result)
        } else {
            let sourceUrl = url.absoluteString.hasPrefix("http://") || url.absoluteString.hasPrefix("https://") ? url : URL(string: "http://\(url)")
            do {
                guard let sourceUrl = sourceUrl else {
                    if !cancellable.isCancelled { onError(.invalidURL(url.absoluteString)) }
                    return
                }
                let data = try Data(contentsOf: sourceUrl)
                var source: NSString? = nil
                NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &source, usedLossyConversion: nil)

                if let source = source {
                    if !cancellable.isCancelled {
                        self.parseHtmlString(source as String, response: response, completion: completion)
                    }
                } else {
                    if !cancellable.isCancelled {
                        onError(.parseError(sourceUrl.absoluteString))
                    }
                }
            } catch let error {
                if !cancellable.isCancelled {
                    let details = "\(sourceUrl?.absoluteString ?? String()): \(error.localizedDescription)"
                    onError(.cannotBeOpened(details))
                }
            }
        }
    }


    private func parseHtmlString(_ htmlString: String, response: Response, completion: @escaping (Response) -> Void) {
        completion(self.performPageCrawling(htmlString, response: response))
    }

    // Perform the page crawiling
    private func performPageCrawling(_ htmlCode: String, response: Response) -> Response {
        var result = response
        //TODO: Consider as error if failed to parse?
        if let doc = try? HTMLDocument(string: htmlCode) {
            result = self.crawlForIcon(doc, response: result)
            
            result = self.crawlMetatags(doc: doc, response: result)
            
            result = self.crawlTitle(htmlCode, result: result)
            
            result = self.crawlDescription(htmlCode, result: result)
            
            result = self.crawlImages(htmlCode, result: result)
        }
        return result
    }


    // Extract canonical URL
    internal func extractCanonicalURL(_ finalUrl: URL) -> String {

        let preUrl: String = finalUrl.absoluteString
        let url = preUrl
            .replace("http://", with: "")
            .replace("https://", with: "")
            .replace("file://", with: "")
            .replace("ftp://", with: "")

        if preUrl != url {

            if let canonicalUrl = Regex.pregMatchFirst(url, regex: Regex.cannonicalUrlPattern, index: 1) {

                if !canonicalUrl.isEmpty {

                    return self.extractBaseUrl(canonicalUrl)

                } else {

                    return self.extractBaseUrl(url)

                }

            } else {

                return self.extractBaseUrl(url)

            }

        } else {

            return self.extractBaseUrl(preUrl)

        }

    }

    // Extract base URL
    fileprivate func extractBaseUrl(_ url: String) -> String {

        return String(url.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)[0])
        
    }

}

// Tag functions
extension SwiftLinkPreview {

    // Search for favicn.
    internal func crawlForIcon(_ doc: HTMLDocument, response: Response) -> Response {
        var result = response
        let links: NodeSet = doc.xpath("//link")
        for link in links {
            if let href = link["href"], let rel = link["rel"] {
                if rel.contains("icon") || rel.contains("shortcut") || rel.contains("apple-touch") {
                    result[.icon] = addImagePrefixIfNeeded(href, response: result)
                    break
                }
            }
        }
        return result
    }
    
    internal func crawlMetatags(doc: HTMLDocument, response: Response) -> Response {
        var result = response
        let metatags: NodeSet = doc.xpath("//meta")
        if let title = crawlMetatags(metatags, for:SwiftLinkResponseKey.title.rawValue) {
            result[.title] = title
        }
        if let description = crawlMetatags(metatags, for:SwiftLinkResponseKey.description.rawValue) {
            result[.description] = description
        }
        if let image = crawlMetatags(metatags, for:SwiftLinkResponseKey.image.rawValue) {
            let value = addImagePrefixIfNeeded(image, response: result)
            if value.isImage() {
                result[.image] = value
            }
        }
        return result
    }
    
    // Search for the given key in metatags.
    // Content with og: and twitter: prefixes is prioritized.
    internal func crawlMetatags(_ metatags: NodeSet, for key: String) -> String? {
        let key = key.lowercased()
        var value: String? = nil
        for metatag in metatags {
            if let content = metatag["content"] {
                let trimmedContent = content.extendedTrim
                if let property = metatag["property"], property == "og:" + key {
                    return trimmedContent
                }
                if let name = metatag["name"], name == ("twitter:" + key) {
                    return trimmedContent
                }
                if let name = metatag["name"], name.lowercased() == key {
                    if value == nil {
                        value = trimmedContent
                    }
                }
                if let itemprop = metatag["itemprop"], itemprop.lowercased() == key {
                    if value == nil {
                        value = trimmedContent
                    }
                }
            }
        }
        return value
    }

    // Crawl for title if needed
    internal func crawlTitle(_ htmlCode: String, result: Response) -> Response {
        var result = result
        let title = result[.title] as? String

        if title == nil || title?.isEmpty ?? true {
            if let value = Regex.pregMatchFirst(htmlCode, regex: Regex.titlePattern, index: 2) {
                if value.isEmpty {
                    let fromBody: String = self.crawlCode(htmlCode, minimum: SwiftLinkPreview.titleMinimumRelevant)
                    if !fromBody.isEmpty {
                        result[.title] = fromBody.decoded.extendedTrim
                        return result
                    }
                } else {
                    result[.title] = value.decoded.extendedTrim
                }
            }
        }

        return result
    }

    // Crawl for description if needed
    internal func crawlDescription(_ htmlCode: String, result: Response) -> Response {
        var result = result
        let description = result[.description] as? String

        if description == nil || description?.isEmpty ?? true {
            let value: String = self.crawlCode(htmlCode, minimum: SwiftLinkPreview.decriptionMinimumRelevant)
            if !value.isEmpty {
                result[.description] = value.decoded.extendedTrim
            }
        }

        return result
    }

    // Crawl for images
    internal func crawlImages(_ htmlCode: String, result: Response) -> Response {

        var result = result

        let mainImage = result[.image] as? String

        if mainImage == nil || mainImage?.isEmpty == true {

            let images = result[.images] as? [String]

            if images == nil || images?.isEmpty ?? true {
                let values = Regex.pregMatchAll(htmlCode, regex: Regex.imageTagPattern, index: 2)
                if !values.isEmpty {
                    let imgs = values.map { self.addImagePrefixIfNeeded($0, response: result) }

                    result[.images] = imgs
                    result[.image] = imgs.first
                }
            }
        } else {
            result[.images] = [self.addImagePrefixIfNeeded(mainImage ?? String(), response: result)]
        }
        return result
    }

    // Add prefix image if needed
    fileprivate func addImagePrefixIfNeeded(_ image: String, response: Response) -> String {

        var image = image

        if let canonicalUrl = response[.canonicalUrl] as? String, let finalUrl = (response[.finalUrl] as? URL)?.absoluteString {
            if finalUrl.hasPrefix("https:") {
                if image.hasPrefix("//") {
                    image = "https:" + image
                } else if image.hasPrefix("/") {
                    image = "https://" + canonicalUrl + image
                }
            } else if image.hasPrefix("//") {
                image = "http:" + image
            } else if image.hasPrefix("/") {
                image = "http://" + canonicalUrl + image
            }
        }

        return removeSuffixIfNeeded(image)

    }

    private func removeSuffixIfNeeded(_ image: String) -> String {

        var image = image

        if let index = image.index(of: "?") { image = String(image[..<index]) }

        return image

    }

    // Crawl the entire code
    internal func crawlCode(_ content: String, minimum: Int) -> String {

        let resultFirstSearch = self.getTagContent("p", content: content, minimum: minimum)

        if !resultFirstSearch.isEmpty {

            return resultFirstSearch

        } else {

            let resultSecondSearch = self.getTagContent("div", content: content, minimum: minimum)

            if !resultSecondSearch.isEmpty {

                return resultSecondSearch

            } else {

                let resultThirdSearch = self.getTagContent("span", content: content, minimum: minimum)

                if !resultThirdSearch.isEmpty {

                    return resultThirdSearch

                } else {

                    if resultThirdSearch.count >= resultFirstSearch.count {

                        if resultThirdSearch.count >= resultThirdSearch.count {

                            return resultThirdSearch

                        } else {

                            return resultThirdSearch
                            
                        }
                        
                    } else {
                        
                        return resultFirstSearch
                        
                    }
                    
                }
                
                
            }
            
        }
        
    }
    
    // Get tag content
    private func getTagContent(_ tag: String, content: String, minimum: Int) -> String {
        
        let pattern = Regex.tagPattern(tag)
        
        let index = 2
        let rawMatches = Regex.pregMatchAll(content, regex: pattern, index: index)
        
        let matches = rawMatches.filter({ $0.extendedTrim.tagsStripped.count >= minimum })
        var result = matches.count > 0 ? matches[0] : ""
        
        if result.isEmpty {
            
            if let match = Regex.pregMatchFirst(content, regex: pattern, index: 2) {
                
                result = match.extendedTrim.tagsStripped
                
            }
            
        }
        
        return result
        
    }
    
}

extension SwiftLinkPreview: URLSessionDataDelegate {

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        request.httpMethod = "GET"
        completionHandler(request)
    }

}
