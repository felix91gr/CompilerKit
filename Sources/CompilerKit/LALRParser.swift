private extension Grammar {
    subscript(_ item: LALRParser<T>.Item) -> Node<T>? {
        let prod = productions[item.term][item.production]
        guard item.position < prod.count else { return nil }
        return prod[item.position]
    }
}

struct LALRParser<T: Hashable> {
    typealias Node = Grammar<T>.Node<T>
    
    struct Item: Hashable {
        let term: Int
        let production: Int
        let position: Int
        
        var next: Item {
            return Item(term: term, production: production, position: position + 1)
        }
    }
    
    // (p, A) where p is state and A is nt
    struct Transition: Hashable {
        let state: Set<Item>
        let nt: Int
    }
    
    enum Action: Hashable {
        case shift
        case reduce(Int, Int, Set<T>)
        case accept
        case error
    }
    
    let grammar: Grammar<T>
    
    init(_ g: Grammar<T>) {
        grammar = g.augmented
    }
    
    static func closure(_ grammar: Grammar<T>, _ I: Set<Item>) -> Set<Item> {
        var J = I
        var lastCount: Int
        repeat {
            lastCount = J.count
            for j in J {
                if let node = grammar[j] {
                    if case let .nt(nt) = node {
                        for x in 0..<grammar.productions[nt].count {
                            J.insert(Item(term: nt, production: x, position: 0))
                        }
                    }
                }
            }
        } while J.count != lastCount
        return J
    }
    
    static func goto(_ grammar: Grammar<T>, _ I: Set<Item>, _ X: Node) -> Set<Item> {
        var G: Set<Item> = []
        for i in I {
            if let node = grammar[i], node == X {
                G.insert(i.next)
            }
        }
        
        return closure(grammar, G)
    }
    
    static func goto(_ grammar: Grammar<T>, _ t: Transition) -> Set<Item> {
        return goto(grammar, t.state, .nt(t.nt))
    }
    
    static func itemSets(_ grammar: Grammar<T>, _ startItem: Item, _ allNodes: Set<Node>) -> Set<Set<Item>> {
        var C: Set<Set<Item>> = [closure(grammar, [startItem])]
        
        var lastCount = 0
        while lastCount != C.count {
            lastCount = C.count
            for I in C {
                for x in allNodes {
                    let g = goto(grammar, I, x)
                    if !g.isEmpty { C.insert(g) }
                }
            }
        }
        
        return C
    }
    
    static func allTransitions(_ grammar: Grammar<T>, _ itemSets: Set<Set<Item>>) -> Set<Transition> {
        var transitions: Set<Transition> = []
        
        for itemSet in itemSets {
            for i in itemSet {
                if case let .nt(nt)? = grammar[i] {
                    transitions.insert(Transition(state: itemSet, nt: nt))
                }
            }
        }
        
        return transitions
    }
    
    static func directRead(_ grammar: Grammar<T>, _ t: Transition) -> Set<T> {
        var terminals: Set<T> = []
        
        let G = goto(grammar, t)
        for i in G {
            if case let .t(terminal)? = grammar[i] {
                terminals.insert(terminal)
            }
        }
        
        return terminals
    }
    
    static func reads(_ grammar: Grammar<T>, _ nullable: [Set<Int>], _ t: Transition) -> Set<Transition> {
        var relations: Set<Transition> = []
        
        let g = goto(grammar, t)
        for i in g {
            guard case let .nt(nt)? = grammar[i.next] else { continue }
            
            if !nullable[nt].isEmpty {
                relations.insert(Transition(state: g, nt: nt))
            }
        }
        
        return relations
    }

    // 't' is (p, A) in DeRemer & Pennello's description of includes
    static func includes(_ grammar: Grammar<T>, _ nullable: [Set<Int>], _ t: Transition, _ allTransitions: Set<Transition>) -> Set<Transition> {
        var includes: Set<Transition> = []
        
        func tailNullable(_ i: Item) -> Bool {
            let prod = grammar.productions[i.term][i.production]
            
            // if item is last in a production, the tail is empty
            // and therefore is nullable
            guard i.position < prod.count else { return true }
            
            let nodes = prod[i.position..<prod.count]
            
            for n in nodes {
                switch n {
                case .t(_): return false
                case let .nt(nt): if !nullable[nt].isEmpty { return false }
                }
            }
            return true
        }
        
        // check every other transtion for being in t's includes
        // 'pre' is (p', B) in DeRemer & Pennello's description of includes
        for pre in allTransitions {
            // find items that reduce to B as candidates for [B -> β A ɣ]
            for initialItem in pre.state where initialItem.term == pre.nt {
                // check all possible (q, C) transitions we can take from this item
                // is our 't' one of them?
                var item = initialItem
                var q = pre.state
                while let node = grammar[item] {
                    if case let .nt(nt) = node {
                        if Transition(state: q, nt: nt) == t {
                            // we just got to (p, A) from 'pre'
                            // this means that this item is [B -> β .A ɣ]
                            // if ɣ is nullable, the (p, A) includes (p', B)
                            // i.e., 't' includes 'pre'
                            if tailNullable(item.next) {
                                includes.insert(pre)
                            }
                        }
                    }
                    
                    q = goto(grammar, q, node)
                    item = item.next
                }
                
            }
        }
        
        return includes
    }
    
    static func lookback(_ grammar: Grammar<T>, _ q: Set<Item>, _ reduction: Item, _ allTransitions: Set<Transition>) -> Set<Transition> {
        let w = grammar.productions[reduction.term][reduction.production]
        // a reduction is represented by an item with the dot in the far right
        // [A -> w.]
        precondition(reduction.position == w.count)
        precondition(q.contains(reduction))
        
        var lookback: Set<Transition> = []
        
        // check every transition (p, A) where A is the reductions lhs
        for t in allTransitions where t.nt == reduction.term {
            // check if we can spell a path from t.state (p) to (q) using w
            var g = t.state
            for n in w {
                g = goto(grammar, g, n)
            }
            
            // if this was a valid path, we will find ourselves at q
            if g == q {
                lookback.insert(t)
            }
        }
        
        return lookback
    }
    
    func parse<S: Sequence>(_ elements: S) -> Bool where S.Element == T {
        let startItem = Item(term: grammar.productions.count - 1, production: 0, position: 0)
        let allNodes = Set(grammar.productions.flatMap { $0.flatMap { $0 } })
        let nullable = grammar.nullable()
        let itemSets = LALRParser.itemSets(grammar, startItem, allNodes)
        let allTransitions = LALRParser.allTransitions(grammar, itemSets)
        
        let directRead = Dictionary(allTransitions) { LALRParser.directRead(grammar, $0) }

        let transitionReads = Dictionary(allTransitions) { LALRParser.reads(grammar, nullable, $0) }
        
        let reads = LALRParser.digraph(allTransitions, transitionReads, directRead)
        
        let transitionIncludes = Dictionary(allTransitions) { LALRParser.includes(grammar, nullable, $0, allTransitions) }
        
        let follow = LALRParser.digraph(allTransitions, transitionIncludes, reads)
        
        // make a list of all possible reduction items: [A -> w.]
        var reductions: [(Set<Item>, Item)] = []
        let prods = grammar.productions
        for term in 0..<prods.count {
            for production in 0..<prods[term].count {
                let r = Item(term: term, production: production, position: prods[term][production].count)
                for state in itemSets where state.contains(r) {
                    reductions.append((state, r))
                }
            }
        }
        
        var lookbacks: [Set<Item>: [Item: Set<Transition>]] = [:]
        for (state, reduction) in reductions {
            lookbacks[state, default: [:]][reduction, default: []] = LALRParser.lookback(grammar, state, reduction, allTransitions)
        }
        
        var lookaheads: [Set<Item>: [Item: Set<T>]] = [:]
        for (state, reduction) in reductions {
            lookaheads[state] = [reduction: []]
            for transition in lookbacks[state]![reduction]! {
                lookaheads[state]![reduction]!.formUnion(follow[transition]!)
            }
        }
        
        // now we (very inefficiently) build a DFA out of that
        let orderedItemSets = Array(itemSets)
        func state(for itemSet: Set<Item>) -> Int {
            return orderedItemSets.index(of: itemSet)!
        }
        
        let startState = state(for: LALRParser.closure(grammar, [startItem]))
        let finalState = state(for: [Item(term: grammar.productions.count - 1, production: 0, position: 1)])
        
        var transitions: [Node: [(Int, Int)]] = [:]
        for from in itemSets {
            for x in allNodes {
                let to = LALRParser.goto(grammar, from, x)
                if !to.isEmpty {
                    transitions[x, default: []].append((state(for: from), state(for: to)))
                }
            }
        }
        
        var accepting: [Int: Set<Action>] = [:]
        for itemSet in itemSets {
            let s = state(for: itemSet)
            
            // if this is a final state, accept, cannot do anything else
            if s == finalState {
                accepting[s] = [.accept]
                continue
            }
            
            if let possibleReductions = lookaheads[itemSet] {
                for (reduction, allowedLookaheads) in possibleReductions {
                    accepting[s, default: []].insert(.reduce(reduction.term, reduction.position, allowedLookaheads))
                }
                
                // the item set also includes non-reduce items, so it can also shift
                if itemSet.count > possibleReductions.count {
                    accepting[s, default: []].insert(.shift)
                }
            } else {
                // no reductions, so the only possible action here is to shift
                accepting[s] = [.shift]
            }
        }
        
        // Can't currently build a DFA directly because DFA.Transition
        // is problematic due to lack of generic covariance in Swift
        let dfa = NFA(
            states: itemSets.count,
            transitions: transitions,
            epsilonTransitions: [:],
            initial: startState,
            accepting: accepting
        ).dfa.minimized
        
        // "we have a parser."
        // now let's use it...
        var stack: [Node] = []
        var it = elements.makeIterator()
        
        var lookahead = it.next()
        func advance() -> T? {
            let current = lookahead
            lookahead = it.next()
            return current
        }
        
        func perform(_ action: Action) -> Bool {
            switch action {
            case .shift:
                guard let t = advance() else { return false }
                stack.append(.t(t))
            case let .reduce(nt, size, _):
                stack.removeLast(size)
                stack.append(.nt(nt))
            case .accept:
                guard lookahead == nil else { return false }
            case .error:
                return false
            }
            
            return true
        }
        
        while true {
            let actions = dfa.match(stack).first ?? [.error]
            let action: Action
            
            switch actions.count {
            case 0: action = .error
            case 1: action = actions.first!
            default:
                // we have a reduce/reduce or shift/reduce conflict
                // is there any viable reduce among the possible actions?
                let viableReduce = actions.first { action in
                    if case let .reduce(_, _, la) = action {
                        if let lookahead = lookahead {
                            return la.contains(lookahead)
                        }
                        return true
                    }
                    return false
                }
                
                if let reduce = viableReduce {
                    action = reduce
                } else if actions.contains(.shift) {
                    action = .shift
                } else {
                    action = .error
                }
            }
            
            if perform(action) {
                if action == .accept { return true }
            } else {
                return false
            }
        }
    }
    
    static func digraph<Input: Hashable, Output: Hashable>(
        _ input: Set<Input>,
        _ relation: [Input: Set<Input>],
        _ fp: [Input: Set<Output>]) -> [Input: Set<Output>] {
        
        var stack: [Input] = []
        var result: [Input: Set<Output>] = [:]
        var n = Dictionary(input) { _ in 0 }
        
        func traverse(_ x: Input) {
            stack.append(x)
            let d = stack.count
            n[x] = d
            result[x] = fp[x]!
            for y in relation[x]! {
                if n[y] == 0 { traverse(y) }
                n[x] = min(n[x]!, n[y]!)
                result[x]!.formUnion(result[y]!)
            }
            if n[x] == d {
                repeat {
                    n[stack.last!] = Int.max
                    result[stack.last!] = result[x]
                } while stack.popLast() != x
            }
        }
        
        for x in input where n[x] == 0 {
            traverse(x)
        }
        
        return result
    }
}
