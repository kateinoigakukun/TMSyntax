import Foundation

internal final class LineParser {
    private static let backReferenceRegex: Regex = try! Regex(pattern: "\\\\(\\d+)", options: [])
    private static let invalidUnicode: Unicode.Scalar = Unicode.Scalar(0xFFFF)!
    private static let invalidString: String = String(String.UnicodeScalarView([invalidUnicode]))
    
    public init(line: String,
                stateStack: ParserStateStack,
                grammer: Grammer,
                isTraceEnabled: Bool)
    {
        self.line = line
        self.lineEndPosition = line.lineEndIndex
        self.position = line.startIndex
        self.isLineEnd = false
        self.stateStack = stateStack
        self.grammer = grammer
        self.tokens = []
        self.isTraceEnabled = isTraceEnabled
    }
    
    private let line: String
    private let lineEndPosition: String.Index
    private var position: String.Index
    private var isLineEnd: Bool
    private var stateStack: ParserStateStack
    private let grammer: Grammer
    private var tokens: [Token]
    private let isTraceEnabled: Bool
    
    public func parse() throws -> Parser.Result {
        while true {
            try parseLine()
            if isLineEnd {
                return Parser.Result(stateStack: stateStack,
                                     tokens: tokens)
            }
        }
    }
    
    private func parseLine() throws {
        if processPhase() {
            return
        }
        
        removePastAnchor()
        let searchEnd = collectSearchEnd()
        let plans = collectMatchPlans()
        
        if isTraceEnabled {
            let positionInByte = line.utf8.distance(from: line.startIndex, to: position)
            trace("--- match plans, position \(positionInByte) ---")
            for (index, plan) in plans.enumerated() {
                trace("[\(index + 1)/\(plans.count)]\(plan)")
            }
            trace("------")
        }
        
        let searchRange = position..<searchEnd.position

        guard let (plan, result) = try search(line: line,
                                              range: searchRange,
                                              plans: plans) else
        {
            trace("no match, end line")
            
            extendOuterScope(range: searchRange)
            self.position = searchRange.upperBound
            
            switch searchEnd {
            case .beginCapture(let anchor):
                processHitAnchor(anchor)
            case .endPosition:
                trace("pop state")
                popState()
            case .line:
                precondition(state.captureAnchors.isEmpty)
                isLineEnd = true
            }
            
            return
        }
        
        extendOuterScope(range: searchRange.lowerBound..<result[].lowerBound)
        self.position = result[].lowerBound
        
        processMatch(plan: plan, result: result)
    }
    
    private var state: ParserState {
        get { return stateStack.top! }
        set { stateStack.top = newValue }
    }
    
    public typealias Exit = Bool
    
    private func processPhase() -> Exit {
        if let phase = state.phase {
            switch phase {
            case .pushContent(let scopeRule):
                trace("apply contentName")
                if let contentName = scopeRule.contentName {
                    state.scopePath.append(contentName)
                }
                state.phase = ParserState.Phase.content(scopeRule)
            case .content:
                break
            case .pop:
                trace("pop")
                popState()
                return true
            }
        }
        
        return false
    }
    
    private func removePastAnchor() {
        var anchors = state.captureAnchors
        anchors.removeAll { (anchor) in
            anchor.range.lowerBound < self.position
        }
        state.captureAnchors = anchors
    }
    
    private func collectSearchEnd() -> SearchEnd {
        var anchors = state.captureAnchors.sorted { (a, b) in
            a.range.lowerBound < b.range.lowerBound
        }
        anchors = anchors.filter { (anchor) in
            self.position <= anchor.range.lowerBound
        }
        if let end = state.endPosition {
            anchors = anchors.filter { (anchor) in
                anchor.range.upperBound <= end
            }
        }
        if let anchor = anchors.first {
            return .beginCapture(anchor)
        }
        if let end = state.endPosition {
            return .endPosition(end)
        }
        return .line(lineEndPosition)
    }
    
    private func collectMatchPlans() -> [MatchPlan] {
        var plans: [MatchPlan] = []
        
        if let endPattern = state.endPattern {
            let endPlan = MatchPlan.endPattern(endPattern)
            plans.append(endPlan)
        }
        
        for rule in state.patterns {
            plans += collectEnterMatchPlans(rule: rule)
        }
        
        return plans
    }
    
    private func collectEnterMatchPlans(rule: Rule) -> [MatchPlan] {
        switch rule.switcher {
        case .include(let rule):
            guard let target = rule.resolve(grammer: grammer) else {
                return []
            }
            return collectEnterMatchPlans(rule: target)
        case .match(let rule):
            return [.matchRule(rule)]
        case .scope(let rule):
            if let begin = rule.begin {
                return [.beginRule(rule, begin)]
            } else {
                var plans: [MatchPlan] = []
                for rule in rule.patterns {
                    plans += collectEnterMatchPlans(rule: rule)
                }
                return plans
            }
        }
    }
        
    private func search(line: String,
                        range: Range<String.Index>,
                        plans: [MatchPlan])
        throws -> (plan: MatchPlan, result: Regex.Match)?
    {
        let patterns = plans.map { $0.pattern }
        
        guard let (index, result) = try search(line: line,
                                               range: range,
                                               patterns: patterns) else
        {
            return nil
        }
        
        return (plan: plans[index], result: result)
    }
    
    private func search(line: String,
                        range: Range<String.Index>,
                        patterns: [RegexPattern])
        throws -> (index: Int, result: Regex.Match)?
    {
        typealias Record = (index: Int, result: Regex.Match)
        
        var records: [Record] = []
        
        for (index, pattern) in patterns.enumerated() {
            let regex = try pattern.compile()
            if let match = regex.search(string: line, range: range) {
                records.append(Record(index: index, result: match))
            }
        }
        
        func cmp(_ a: Record, _ b: Record) -> Bool {
            let (ai, am) = a
            let (bi, bm) = b
            
            if am[].lowerBound != bm[].lowerBound {
                return am[].lowerBound < bm[].lowerBound
            }
            
            return ai < bi
        }
        
        return records.min(by: cmp)
    }
    
    private func processMatch(plan: MatchPlan, result regexMatch: Regex.Match) {
        trace("match!: \(plan)")
        
        switch plan {
        case .matchRule(let rule):
            var scopePath = state.scopePath
            if let scope = rule.scopeName {
                scopePath.append(scope)
            }
            
            let anchor0 = buildCaptureAnchor(regexMatch: regexMatch,
                                             captures: rule.captures)
            let newState = ParserState(phase: nil,
                                       patterns: [],
                                       captureAnchors: anchor0.map { [$0] } ?? [],
                                       scopePath: scopePath,
                                       endPattern: nil,
                                       endPosition: regexMatch[].upperBound)
            trace("push state")
            pushState(newState)
            
            if let anchor0 = anchor0 {
                processHitAnchor(anchor0)
            }
        case .beginRule(let rule, _):
            var scopePath = state.scopePath
            if let scope = rule.scopeName {
                scopePath.append(scope)
            }
            
            let ruleEndPattern = rule.end!
            let endPattern = resolveEndPatternBackReference(end: ruleEndPattern,
                                                            beginMatchResult: regexMatch)
            
            let anchor0 = buildCaptureAnchor(regexMatch: regexMatch,
                                             captures: rule.beginCaptures)
            
            let newState = ParserState(phase: .pushContent(rule),
                                       patterns: rule.patterns,
                                       captureAnchors: anchor0.map { [$0] } ?? [],
                                       scopePath: scopePath,
                                       endPattern: endPattern,
                                       endPosition: nil)
            trace("push state")
            pushState(newState)
            
            if let anchor0 = anchor0 {
                processHitAnchor(anchor0)
            }
        case .endPattern:
            let scopeRule = state.scopeRule!
            
            // end of contentName
            if let contentName = scopeRule.contentName {
                precondition(contentName == state.scopePath.last)
                state.scopePath.removeLast()
            }
            
            state.phase = ParserState.Phase.pop(scopeRule)
            
            if let anchor0 = buildCaptureAnchor(regexMatch: regexMatch,
                                                captures: scopeRule.endCaptures) {
                processHitAnchor(anchor0)
            }
        }
    }
    
    private func processHitAnchor(_ anchor: CaptureAnchor) {
        var scopePath = state.scopePath
        if let scope = anchor.attribute?.name {
            scopePath.append(scope)
        }
        
        let newState = ParserState(phase: nil,
                                   patterns: anchor.attribute?.patterns ?? [],
                                   captureAnchors: anchor.children,
                                   scopePath: scopePath,
                                   endPattern: nil,
                                   endPosition: anchor.range.upperBound)
        trace("push state: anchor")
        pushState(newState)
    }
    
    private func buildCaptureAnchor(regexMatch: Regex.Match,
                                    captures: CaptureAttributes?) -> CaptureAnchor?
    {
        if regexMatch[].isEmpty {
            return nil
        }
        
        var subAnchors: [CaptureAnchor] = []
        
        if let captures = captures {
            for (key, capture) in captures.dictionary {
                guard let index = Int(key),
                    index != 0,
                    let range = regexMatch[index],
                    !range.isEmpty else
                {
                    continue
                }
                
                subAnchors.append(CaptureAnchor(attribute: capture,
                                                range: range,
                                                children: []))
            }
        }
        
        func _capture0() -> CaptureAttribute? {
            if let captures = captures,
                let capture0 = captures.dictionary["0"]
            {
                return capture0
            }
            return nil
        }
        
        return CaptureAnchor(attribute: _capture0(),
                             range: regexMatch[],
                             children: subAnchors)
    }
    
    private func resolveEndPatternBackReference(end: RegexPattern,
                                                beginMatchResult: Regex.Match) -> RegexPattern
    {
        var num = 0
        
        let newPattern = LineParser.backReferenceRegex.replace(string: end.value) { (match) in
            num += 1
            
            let captureIndex = Int(end.value[match[1]!])!
            
            guard let range = beginMatchResult[captureIndex] else {
                return LineParser.invalidString
            }
            return String(line[range])
        }
        
        if num == 0 {
            // return same object
            return end
        }
        
        return RegexPattern(newPattern, location: end.location)
    }
    
    private func extendOuterScope(range: Range<String.Index>) {
        guard !range.isEmpty else {
            return
        }
        
        let token = Token(range: range,
                          scopePath: state.scopePath)
        addToken(token)
    }
    
    private func pushState(_ newState: ParserState) {
        var newState = newState
        
        if let stateEnd = newState.endPosition,
            let currentEnd = self.state.endPosition,
            currentEnd < stateEnd
        {
            newState.endPosition = currentEnd
        }
        
        stateStack.stack.append(newState)
    }
    
    private func popState() {
        stateStack.stack.removeLast()
    }
    
    private func addToken(_ token: Token) {
        tokens.append(token)
    }
    
    private func trace(_ string: String) {
        if isTraceEnabled {
            print("[Parser trace] \(string)")
        }
    }

}
