import SwiftUI

private let ocean = Color(red: 0.035, green: 0.09, blue: 0.16)
private let panel = Color(red: 0.055, green: 0.14, blue: 0.23)
private let cyan = Color(red: 0.26, green: 0.82, blue: 0.91)
private let muted = Color(red: 0.55, green: 0.68, blue: 0.77)

@main
struct BattleFleetApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
                .frame(minWidth: 990, minHeight: 730)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}

struct Cell: Hashable {
    let row: Int
    let col: Int
}

struct Ship: Identifiable {
    let id = UUID()
    let name: String
    let length: Int
    let cells: Set<Cell>
}

// 進行状態に応じて、配置・対戦・勝敗画面を切り替える。
enum GamePhase { case setup, playing, won, lost }

// 盤面の状態と、プレイヤー／CPU双方の行動をまとめて管理する。
@MainActor
final class GameModel: ObservableObject {
    @Published var level = 4
    @Published var gridSize = 10
    @Published var phase: GamePhase = .setup
    @Published var playerShips: [Ship] = []
    @Published var cpuShips: [Ship] = []
    @Published var playerShots = Set<Cell>()
    @Published var cpuShots = Set<Cell>()
    @Published var playerHits = Set<Cell>()
    @Published var cpuHits = Set<Cell>()
    @Published var message = "艦隊を確認して、出撃準備を整えよう。"
    @Published var cpuThinking = false
    @Published var lastPlayerShot: Cell?
    @Published var lastCPUShot: Cell?

    let fleet = [("戦艦", 5), ("巡洋艦", 4), ("駆逐艦", 3), ("潜水艦", 3), ("哨戒艇", 2)]

    init() { resetSetup() }

    func resetSetup() {
        // 再戦や盤面変更時は、両艦隊と射撃履歴をまとめて初期化する。
        playerShips = makeFleet()
        cpuShips = makeFleet()
        playerShots = []; cpuShots = []; playerHits = []; cpuHits = []
        lastPlayerShot = nil; lastCPUShot = nil
        phase = .setup
        cpuThinking = false
        message = "艦隊を確認して、出撃準備を整えよう。"
    }

    private func makeFleet() -> [Ship] {
        var occupied = Set<Cell>()
        var result: [Ship] = []
        for (name, length) in fleet {
            var placed = false
            while !placed {
                // 盤面サイズに合わせて向きと先頭位置を選び、重ならない場所を探す。
                let horizontal = Bool.random()
                let row = Int.random(in: 0..<gridSize)
                let col = Int.random(in: 0..<gridSize)
                guard (horizontal ? col + length : row + length) <= gridSize else { continue }
                let cells = Set((0..<length).map { i in Cell(row: row + (horizontal ? 0 : i), col: col + (horizontal ? i : 0)) })
                if cells.isDisjoint(with: occupied) {
                    occupied.formUnion(cells)
                    result.append(Ship(name: name, length: length, cells: cells))
                    placed = true
                }
            }
        }
        return result
    }

    func start() {
        guard phase == .setup else { return }
        phase = .playing
        message = "作戦開始。敵艦の位置を探ろう。"
    }

    func setGridSize(_ size: Int) {
        guard [10, 15, 20].contains(size), size != gridSize else { return }
        gridSize = size
        resetSetup()
    }

    func fire(at cell: Cell) {
        // 対戦中以外、CPU思考中、または既に撃ったマスへの射撃は受け付けない。
        guard phase == .playing, !cpuThinking, !playerShots.contains(cell) else { return }
        playerShots.insert(cell)
        lastPlayerShot = cell
        if cpuShips.contains(where: { $0.cells.contains(cell) }) {
            playerHits.insert(cell)
            if cpuShips.allSatisfy({ $0.cells.isSubset(of: playerHits) }) {
                phase = .won
                message = "全敵艦を撃沈！見事な勝利だ。"
                return
            }
            let ship = cpuShips.first { $0.cells.contains(cell) }!
            let sunk = ship.cells.isSubset(of: playerHits)
            message = sunk ? "敵の\(ship.name)を撃沈！" : "命中！敵艦に損害を与えた。"
        } else {
            message = "外れ。敵艦の航路を読み直そう。"
        }
        cpuThinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.cpuFire() }
    }

    private func cpuFire() {
        guard phase == .playing else { cpuThinking = false; return }
        let target = chooseCPUTarget()
        cpuShots.insert(target)
        lastCPUShot = target
        cpuThinking = false
        if playerShips.contains(where: { $0.cells.contains(target) }) {
            cpuHits.insert(target)
            if playerShips.allSatisfy({ $0.cells.isSubset(of: cpuHits) }) {
                phase = .lost
                message = "艦隊が全滅した。もう一度作戦を立て直そう。"
                return
            }
            message = "CPUが命中させた！こちらも反撃を。"
        } else {
            message = "CPUの攻撃は外れた。反撃のチャンス！"
        }
    }

    private func chooseCPUTarget() -> Cell {
        // 既に撃ったマスを候補から除き、選択中の難易度に応じて狙い方を変える。
        let available = (0..<gridSize).flatMap { r in (0..<gridSize).map { c in Cell(row: r, col: c) } }.filter { !cpuShots.contains($0) }
        guard level > 1 else { return available.randomElement()! }
        let adjacent = available.filter { candidate in
            cpuHits.contains { hit in abs(hit.row - candidate.row) + abs(hit.col - candidate.col) == 1 }
        }
        let useTargeting = level >= 5 || Double.random(in: 0..<1) < Double(level - 1) / 8.0
        if useTargeting, !adjacent.isEmpty {
            if level >= 8, let aligned = alignedContinuation(from: adjacent) { return aligned }
            return adjacent.randomElement()!
        }
        if level == 10, let probabilityTarget = probabilityShot(from: available) { return probabilityTarget }
        if level >= 6 {
            let huntCells = available.filter { ($0.row + $0.col).isMultiple(of: 2) }
            if !huntCells.isEmpty { return huntCells.randomElement()! }
        }
        return available.randomElement()!
    }

    private func probabilityShot(from available: [Cell]) -> Cell? {
        // LV10用。残存艦の長さごとに、外れマスを避ける合法な配置をすべて数える。
        let sunkCells = playerShips.filter { $0.cells.isSubset(of: cpuHits) }.reduce(into: Set<Cell>()) { $0.formUnion($1.cells) }
        let activeLengths = playerShips.filter { !$0.cells.isSubset(of: cpuHits) }.map(\.length)
        var scores = Dictionary(uniqueKeysWithValues: available.map { ($0, 0) })
        for length in activeLengths {
            for horizontal in [true, false] {
                for row in 0..<gridSize {
                    for col in 0..<gridSize {
                        guard (horizontal ? col + length : row + length) <= gridSize else { continue }
                        let placement = (0..<length).map { i in Cell(row: row + (horizontal ? 0 : i), col: col + (horizontal ? i : 0)) }
                        let cells = Set(placement)
                        guard cells.isDisjoint(with: sunkCells), placement.allSatisfy({ !cpuShots.contains($0) || cpuHits.contains($0) }) else { continue }
                        for cell in placement where scores[cell] != nil { scores[cell, default: 0] += 1 }
                    }
                }
            }
        }
        let bestScore = scores.values.max() ?? 0
        guard bestScore > 0 else { return nil }
        return scores.filter { $0.value == bestScore }.keys.randomElement()
    }

    private func alignedContinuation(from candidates: [Cell]) -> Cell? {
        // 命中が同じ行・列に複数あるときは、艦の向きを推定して端を狙う。
        for hit in cpuHits {
            let sameRow = cpuHits.filter { $0.row == hit.row }
            let sameCol = cpuHits.filter { $0.col == hit.col }
            if sameRow.count >= 2 {
                let row = sameRow.first!.row
                let minCol = sameRow.map(\.col).min()!, maxCol = sameRow.map(\.col).max()!
                if let next = candidates.first(where: { $0.row == row && ($0.col == minCol - 1 || $0.col == maxCol + 1) }) { return next }
            }
            if sameCol.count >= 2 {
                let col = sameCol.first!.col
                let minRow = sameCol.map(\.row).min()!, maxRow = sameCol.map(\.row).max()!
                if let next = candidates.first(where: { $0.col == col && ($0.row == minRow - 1 || $0.row == maxRow + 1) }) { return next }
            }
        }
        return nil
    }

    func ship(at cell: Cell, onPlayerBoard: Bool) -> Bool {
        (onPlayerBoard ? playerShips : cpuShips).contains { $0.cells.contains(cell) }
    }
    func sunk(at cell: Cell, onPlayerBoard: Bool) -> Bool {
        let ships = onPlayerBoard ? playerShips : cpuShips
        let hits = onPlayerBoard ? cpuHits : playerHits
        return ships.first { $0.cells.contains(cell) }?.cells.isSubset(of: hits) ?? false
    }
    var playerRemaining: Int { playerShips.filter { !$0.cells.isSubset(of: cpuHits) }.count }
    var enemyRemaining: Int { cpuShips.filter { !$0.cells.isSubset(of: playerHits) }.count }
    var turnLabel: String {
        switch phase {
        case .setup: "出撃準備"
        case .playing: cpuThinking ? "CPUの攻撃中…" : "あなたのターン"
        case .won: "ミッション成功"
        case .lost: "ミッション失敗"
        }
    }
}

struct GameView: View {
    @StateObject private var game = GameModel()

    var body: some View {
        ZStack {
            ocean.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 20) {
                        statusBar
                        HStack(alignment: .top, spacing: 18) {
                            boardCard(title: "敵艦隊", subtitle: "TARGET GRID", playerBoard: false)
                            boardCard(title: "自艦隊", subtitle: "YOUR FLEET", playerBoard: true)
                        }
                        bottomPanel
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 20)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(cyan.opacity(0.14)).frame(width: 46, height: 46)
                Image(systemName: "water.waves").font(.system(size: 22, weight: .bold)).foregroundStyle(cyan)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("海戦司令部").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("BATTLE FLEET  /  PACIFIC COMMAND").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4).foregroundStyle(muted)
            }
            Spacer()
            Text("MAC EDITION").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(cyan.opacity(0.8))
        }
        .padding(.horizontal, 28).padding(.vertical, 17)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(game.phase == .playing ? cyan : (game.phase == .won ? .green : (game.phase == .lost ? .red : .orange))).frame(width: 7, height: 7)
                    Text(game.turnLabel.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(cyan)
                }
                Text(game.message).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.92))
            }
            Spacer()
            HStack(spacing: 18) {
                countStat(title: "敵艦", count: game.enemyRemaining)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 30)
                countStat(title: "自艦", count: game.playerRemaining)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func countStat(title: String, count: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            Text("\(count)隻").font(.system(size: 17, weight: .bold, design: .rounded))
        }
    }

    // 盤面が大きくなってもマスを正方形に保てるよう、サイズごとの一辺を決める。
    private var cellSide: CGFloat {
        switch game.gridSize {
        case 15: 20
        case 20: 15
        default: 27
        }
    }

    private var cellGap: CGFloat { game.gridSize == 10 ? 3 : 2 }
    private var rowLabelWidth: CGFloat { game.gridSize == 20 ? 20 : 17 }
    private var gridWidth: CGFloat {
        rowLabelWidth + cellGap + CGFloat(game.gridSize) * cellSide + CGFloat(game.gridSize - 1) * cellGap
    }
    private var gridHeight: CGFloat {
        16 + cellGap + CGFloat(game.gridSize) * cellSide + CGFloat(game.gridSize - 1) * cellGap
    }

    private func boardCard(title: String, subtitle: String, playerBoard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 17, weight: .bold))
                Text(subtitle).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.3).foregroundStyle(muted)
                Spacer()
                if !playerBoard && game.phase == .playing {
                    Label("攻撃可能", systemImage: "scope").font(.system(size: 10, weight: .medium)).foregroundStyle(cyan)
                }
            }
            boardGrid(playerBoard: playerBoard)
            if playerBoard { fleetList } else {
                HStack(spacing: 14) {
                    legendDot(color: Color(red: 0.95, green: 0.38, blue: 0.30), text: "命中")
                    legendDot(color: muted, text: "外れ")
                    legendDot(color: cyan, text: "直近の攻撃")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private func boardGrid(playerBoard: Bool) -> some View {
        if playerBoard { playerBoardGrid }
        else { targetBoardGrid }
    }

    private var targetBoardGrid: some View {
        VStack(spacing: cellGap) {
            HStack(spacing: cellGap) {
                Color.clear.frame(width: rowLabelWidth, height: 16)
                ForEach(0..<game.gridSize, id: \.self) { col in
                    Text(String(UnicodeScalar(65 + col)!))
                        .frame(width: cellSide, height: 16)
                        .font(.system(size: game.gridSize == 20 ? 7 : 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(muted)
                }
            }
            ForEach(0..<game.gridSize, id: \.self) { row in
                HStack(spacing: cellGap) {
                    Text("\(row + 1)")
                        .frame(width: rowLabelWidth, height: cellSide)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(muted)
                    ForEach(0..<game.gridSize, id: \.self) { col in
                        let cell = Cell(row: row, col: col)
                        Button { game.fire(at: cell) } label: {
                            cellView(cell, playerBoard: false).frame(width: cellSide, height: cellSide)
                        }
                        .buttonStyle(.plain)
                        .disabled(game.phase != .playing || game.playerShots.contains(cell) || game.cpuThinking)
                        .help("\(String(UnicodeScalar(65 + col)!))\(row + 1)")
                    }
                }
            }
        }
        .frame(width: gridWidth)
        .frame(maxWidth: .infinity)
    }

    private var playerBoardGrid: some View {
        GeometryReader { _ in
            let side = cellSide
            let gap = cellGap
            let stride = side + gap
            ZStack(alignment: .topLeading) {
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        Color.clear.frame(width: rowLabelWidth, height: 16)
                        ForEach(0..<game.gridSize, id: \.self) { col in
                            Text(String(UnicodeScalar(65 + col)!))
                                .frame(width: side, height: 16)
                                .font(.system(size: game.gridSize == 20 ? 7 : 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(muted)
                        }
                    }
                    ForEach(0..<game.gridSize, id: \.self) { row in
                        HStack(spacing: gap) {
                            Text("\(row + 1)")
                                .frame(width: rowLabelWidth, height: side)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(muted)
                            ForEach(0..<game.gridSize, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(red: 0.08, green: 0.22, blue: 0.32))
                                    .frame(width: side, height: side)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.05), lineWidth: 0.6))
                            }
                        }
                    }
                }

                // 船体を占有マスの外接範囲に合わせ、縦向きの艦は中心を保って回転する。
                ForEach(game.playerShips) { ship in
                    let minRow = ship.cells.map(\.row).min() ?? 0
                    let minCol = ship.cells.map(\.col).min() ?? 0
                    let vertical = ship.cells.map(\.col).allSatisfy { $0 == minCol }
                    let span = side * CGFloat(ship.length) + gap * CGFloat(ship.length - 1)
                    let centerX = rowLabelWidth + gap + side / 2 + CGFloat(minCol) * stride + (vertical ? 0 : CGFloat(ship.length - 1) * stride / 2)
                    let centerY = 16 + gap + side / 2 + CGFloat(minRow) * stride + (vertical ? CGFloat(ship.length - 1) * stride / 2 : 0)
                    ShipSilhouette()
                        .fill(ship.cells.isSubset(of: game.cpuHits) ? Color.red.opacity(0.85) : Color(red: 0.45, green: 0.78, blue: 0.88))
                        .overlay(ShipSilhouette().stroke(Color.white.opacity(0.45), lineWidth: 0.7))
                        .frame(width: span, height: side)
                        .rotationEffect(vertical ? .degrees(90) : .zero)
                        .position(x: centerX, y: centerY)
                }

                // 艦の形で隠れないよう、被弾・着弾マークを最後に重ねる。
                ForEach(0..<game.gridSize, id: \.self) { row in
                    ForEach(0..<game.gridSize, id: \.self) { col in
                        let cell = Cell(row: row, col: col)
                        if game.cpuShots.contains(cell) {
                            let isHit = game.cpuHits.contains(cell)
                            ZStack {
                                if isHit {
                                    Image(systemName: "xmark").font(.system(size: 11, weight: .black)).foregroundStyle(.white)
                                } else {
                                    Circle().fill(muted.opacity(0.9)).frame(width: 5, height: 5)
                                }
                                if game.lastCPUShot == cell {
                                    RoundedRectangle(cornerRadius: 4).stroke(cyan, lineWidth: 2)
                                }
                            }
                            .frame(width: side, height: side)
                            .position(x: rowLabelWidth + gap + side / 2 + CGFloat(col) * stride, y: 16 + gap + side / 2 + CGFloat(row) * stride)
                        }
                    }
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: gridHeight)
    }

    @ViewBuilder
    private func cellView(_ cell: Cell, playerBoard: Bool) -> some View {
        let isShip = playerBoard && game.ship(at: cell, onPlayerBoard: true)
        let hit = playerBoard ? game.cpuHits.contains(cell) : game.playerHits.contains(cell)
        let miss = playerBoard ? game.cpuShots.contains(cell) && !hit : game.playerShots.contains(cell) && !hit
        let latest = playerBoard ? game.lastCPUShot == cell : game.lastPlayerShot == cell
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(hit ? Color(red: 0.78, green: 0.22, blue: 0.20) : (isShip ? Color(red: 0.18, green: 0.43, blue: 0.57) : Color(red: 0.08, green: 0.22, blue: 0.32)))
            if miss { Circle().fill(muted.opacity(0.78)).frame(width: 5, height: 5) }
            if hit { Image(systemName: "xmark").font(.system(size: 11, weight: .black)).foregroundStyle(.white) }
            if latest { RoundedRectangle(cornerRadius: 4).stroke(cyan, lineWidth: 2) }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(isShip ? 0.16 : 0.05), lineWidth: 0.6))
        .contentShape(RoundedRectangle(cornerRadius: 4))
    }

    private var fleetList: some View {
        VStack(spacing: 5) {
            ForEach(game.playerShips) { ship in
                let destroyed = ship.cells.isSubset(of: game.cpuHits)
                HStack(spacing: 8) {
                    Text(ship.name).font(.system(size: 11, weight: .medium)).foregroundStyle(destroyed ? muted : .white.opacity(0.9))
                    ShipSilhouette().fill(destroyed ? Color.red.opacity(0.55) : cyan.opacity(0.82)).frame(width: CGFloat(ship.length) * 17, height: 13)
                    Spacer(minLength: 4)
                    Text(destroyed ? "沈没" : "\(ship.length)区画").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.top, 1)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(muted) }
    }

    private var bottomPanel: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text("盤面").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                    ForEach([10, 15, 20], id: \.self) { size in
                        Button { game.setGridSize(size) } label: {
                            Text("\(size)×\(size)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(game.gridSize == size ? ocean : cyan)
                                .frame(width: 48, height: 24)
                                .background(game.gridSize == size ? cyan : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(game.phase == .playing)
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    Text("CPU").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted).frame(width: 35, alignment: .leading)
                    HStack(spacing: 6) {
                        ForEach(1...10, id: \.self) { value in
                            Button { game.level = value } label: {
                                Text("\(value)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(game.level == value ? ocean : (value <= game.level ? cyan : muted))
                                    .frame(width: 27, height: 27)
                                    .background(game.level == value ? cyan : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1, height: 62)
            VStack(alignment: .leading, spacing: 4) {
                Text("LEVEL \(String(format: "%02d", game.level))").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(cyan)
                Text(levelDescription).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            }.frame(width: 155, alignment: .leading)
            Spacer(minLength: 8)
            if game.phase == .setup {
                Button { game.resetSetup() } label: {
                    Label("艦隊を再配置", systemImage: "shuffle").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(SecondaryButtonStyle())
                Button { game.start() } label: {
                    Label("出撃する", systemImage: "paperplane.fill").font(.system(size: 12, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 10)
                }.buttonStyle(PrimaryButtonStyle())
            } else if game.phase == .playing {
                Label("敵艦隊を撃沈せよ", systemImage: "scope").font(.system(size: 11, weight: .semibold)).foregroundStyle(cyan).padding(.horizontal, 15).padding(.vertical, 10).background(cyan.opacity(0.1), in: Capsule())
            } else {
                Button { game.resetSetup() } label: {
                    Label("もう一度プレイ", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .bold)).padding(.horizontal, 16).padding(.vertical, 10)
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private var levelDescription: String {
        switch game.level {
        case 1: "ランダムに攻撃する新兵"
        case 2...4: "命中地点の周囲を時々探索"
        case 5...7: "命中した艦を追跡する熟練者"
        case 8...9: "艦の向きを読んで追撃するエース"
        default: "配置候補を計算する最強司令官"
        }
    }
}

// 座標に合わせて描画される艦のシルエット。盤面上ではマス幅に合わせて拡大縮小する。
private struct ShipSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()

        // 船体の輪郭。
        path.move(to: CGPoint(x: w * 0.03, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.81, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.98, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.89, y: h * 0.89))
        path.addLine(to: CGPoint(x: w * 0.12, y: h * 0.89))
        path.addLine(to: CGPoint(x: w * 0.02, y: h * 0.72))
        path.closeSubpath()

        // 甲板、艦橋、マスト、砲塔を小さな多角形として重ねる。
        path.addRect(CGRect(x: w * 0.25, y: h * 0.39, width: w * 0.48, height: h * 0.15))
        path.addRect(CGRect(x: w * 0.39, y: h * 0.24, width: w * 0.27, height: h * 0.15))
        path.addRect(CGRect(x: w * 0.49, y: h * 0.09, width: w * 0.035, height: h * 0.15))
        path.addRect(CGRect(x: w * 0.77, y: h * 0.43, width: w * 0.08, height: h * 0.08))
        return path
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(ocean).background(configuration.isPressed ? cyan.opacity(0.75) : cyan, in: RoundedRectangle(cornerRadius: 9)).scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 12).padding(.vertical, 9).background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
