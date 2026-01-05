// Global variables
let chart;
let candleSeries;
let activeLines = {}; // Store { ticket: { sl: PriceLine, tp: PriceLine, entry: PriceLine, data: rawPos } }
let isDragging = false;
let draggedLine = null; // { type: 'sl'|'tp', ticket: int, originalPrice: float, lineObj: PriceLine }
let dragStartY = 0;

const container = document.getElementById('chart-container');

function initChart() {
    try {
        if (typeof LightweightCharts === 'undefined') {
            console.error("LightweightCharts library is not loaded!");
            document.body.innerHTML = "<h2 style='color:red'>Error: Library not loaded</h2>";
            return;
        }

        chart = LightweightCharts.createChart(container, {
            width: container.clientWidth,
            height: container.clientHeight,
            layout: {
                background: { type: 'solid', color: '#1c212e' },
                textColor: '#d1d4dc',
                fontSize: 10, // Adjusted to 10px as requested
            },
            grid: {
                vertLines: { color: 'rgba(42, 46, 57, 0.5)' },
                horzLines: { color: 'rgba(42, 46, 57, 0.5)' },
            },
            rightPriceScale: {
                borderColor: 'rgba(197, 203, 206, 0.8)',
                scaleMargins: {
                    top: 0.2, // Increase to preventing label flipping
                    bottom: 0.2,
                },
            },
            timeScale: {
                borderColor: 'rgba(197, 203, 206, 0.8)',
                timeVisible: true,
                secondsVisible: false,
                barSpacing: 12, // Increased from default (6)
                minBarSpacing: 1,
            },
            crosshair: {
                mode: LightweightCharts.CrosshairMode.Normal,
            },
            handleScroll: {
                vertTouchDrag: true, // Allow chart vertical scroll
            },
            handleScale: {
                axisPressedMouseMove: true,
            }
        });

        candleSeries = chart.addSeries(LightweightCharts.CandlestickSeries, {
            upColor: '#26a69a',
            downColor: '#ef5350',
            borderVisible: false,
            wickUpColor: '#26a69a',
            wickDownColor: '#ef5350',
        });

        // Handle Resize
        window.addEventListener('resize', () => {
            if (chart) chart.resize(container.clientWidth, container.clientHeight);
        });

        // Init Drag Events
        initDragEvents();

        console.log("TradingView Chart Initialized");
    } catch (e) {
        console.error("Error initializing chart:", e);
    }
}

// ==========================================
// Custom Drag & Drop Logic
// ==========================================

function initDragEvents() {
    // Mouse Events
    container.addEventListener('mousedown', onDragStart);
    container.addEventListener('mousemove', onDragMove);
    container.addEventListener('mouseup', onDragEnd);
    container.addEventListener('mouseleave', onDragEnd); // Safety

    // Touch Events (for mobile)
    container.addEventListener('touchstart', onTouchStart, { passive: false });
    container.addEventListener('touchmove', onTouchMove, { passive: false });
    container.addEventListener('touchend', onDragEnd);
}

// Menu HTML Injection
const menuDiv = document.createElement('div');
menuDiv.id = 'context-menu';
menuDiv.innerHTML = `
    <button class="menu-btn" id="btn-tp">Set TP</button>
    <button class="menu-btn" id="btn-sl">Set SL</button>
    <button class="menu-btn close-pos" id="btn-close">Close Position</button>
    <button class="menu-btn cancel-menu" id="btn-cancel">Cancel</button>
`;
document.body.appendChild(menuDiv);

let openMenuTicket = null;

function showContextMenu(x, y, ticket) {
    if (isDragging) return;
    openMenuTicket = ticket;

    // Position
    const maxX = container.clientWidth - 150;
    const maxY = container.clientHeight - 150;

    menuDiv.style.left = Math.min(x, maxX) + 'px';
    menuDiv.style.top = Math.min(y, maxY) + 'px';
    menuDiv.style.display = 'block';

    // Bind actions
    document.getElementById('btn-tp').onclick = () => { actionSetLine('TP'); hideMenu(); };
    document.getElementById('btn-sl').onclick = () => { actionSetLine('SL'); hideMenu(); };
    document.getElementById('btn-close').onclick = () => { actionClosePos(); hideMenu(); };
    document.getElementById('btn-cancel').onclick = hideMenu;
}

function hideMenu() {
    menuDiv.style.display = 'none';
    openMenuTicket = null;
}

function actionSetLine(type) {
    if (!openMenuTicket) return;
    const group = activeLines[openMenuTicket];
    if (!group) return;

    // Create line if not exists
    const entryPrice = group.data.price_open;
    const isBuy = group.data.type.toString().toUpperCase().includes("BUY");

    // Default distances (approx 0.1%)
    const delta = entryPrice * 0.001;
    let targetPrice = entryPrice;

    if (type === 'TP') {
        targetPrice = isBuy ? entryPrice + delta : entryPrice - delta;
    } else {
        targetPrice = isBuy ? entryPrice - delta : entryPrice + delta;
    }

    // Send to Flutter to create/modify
    if (window.PositionModified) {
        window.PositionModified.postMessage(JSON.stringify({
            ticket: parseInt(openMenuTicket),
            type: type,
            price: targetPrice
        }));
    }
}

function actionClosePos() {
    if (!openMenuTicket) return;
    if (window.PositionModified) {
        window.PositionModified.postMessage(JSON.stringify({
            ticket: parseInt(openMenuTicket),
            type: 'CLOSE',
            price: 0
        }));
    }
}

// Modify Drag Logic to detect Click
let dragStartTime = 0;
let startX = 0;
let startY = 0;

// Track ticket for potential tap on Entry
let potentialTapTicket = null;

function onDragStart(e) {
    const price = getPriceFromEvent(e);
    if (price === null) return;

    hideMenu(); // Close if open elsewhere

    // Standardize Coordinates (Viewport) for click tracking
    const clickY = (e.touches && e.touches[0] ? e.touches[0].clientY : e.clientY) || e.offsetY;
    const clickX = (e.touches && e.touches[0] ? e.touches[0].clientX : e.clientX) || e.offsetX;

    // Store for click detection
    dragStartTime = Date.now();
    startX = clickX;
    startY = clickY;
    potentialTapTicket = null;

    let bestMatch = null;
    let minDist = 30; // Tolerance

    // Hit Test Y (Element Relative) for finding lines
    const rect = container.getBoundingClientRect();
    const hitTestY = e.offsetY || (e.touches && e.touches[0] ? e.touches[0].clientY - rect.top : 0);

    // Iterate active lines
    for (const ticket in activeLines) {
        const group = activeLines[ticket];

        // 1. Check SL/TP first (Draggable)
        if (group.sl) {
            const lineY = candleSeries.priceToCoordinate(group.sl.options().price);
            if (lineY !== null && Math.abs(lineY - hitTestY) < minDist) {
                bestMatch = { ticket: ticket, type: 'sl', lineObj: group.sl, isExisting: true };
                break;
            }
        }
        if (group.tp) {
            const lineY = candleSeries.priceToCoordinate(group.tp.options().price);
            if (lineY !== null && Math.abs(lineY - hitTestY) < minDist) {
                bestMatch = { ticket: ticket, type: 'tp', lineObj: group.tp, isExisting: true };
                break;
            }
        }

        // 2. Check Entry (Tap Only - NOT Draggable)
        if (!bestMatch && group.entryLine) {
            const lineY = candleSeries.priceToCoordinate(group.entryLine.options().price);
            if (lineY !== null && Math.abs(lineY - hitTestY) < minDist) {
                potentialTapTicket = ticket;
            }
        }
    }

    if (bestMatch) {
        isDragging = true;
        draggedLine = bestMatch;
        chart.applyOptions({ handleScroll: false, handleScale: false });
        container.classList.add('grabbing');
    }
}

function onDragMove(e) {
    if (!isDragging || !draggedLine) return;

    const price = getPriceFromEvent(e);
    if (price) {
        draggedLine.lineObj.applyOptions({ price: price });
    }
}

function onDragEnd(e) {
    const now = Date.now();

    // Coordinates
    let endX = e.clientX;
    let endY = e.clientY;
    if (e.changedTouches && e.changedTouches.length > 0) {
        endX = e.changedTouches[0].clientX;
        endY = e.changedTouches[0].clientY;
    } else if (endX === undefined) {
        endX = e.clientX || e.pageX;
        endY = e.clientY || e.pageY;
    }

    const dist = Math.sqrt(Math.pow(endX - startX, 2) + Math.pow(endY - startY, 2));

    // 1. Handle Drag End (SL/TP)
    if (isDragging && draggedLine) {
        // Commit Change
        const finalPrice = draggedLine.lineObj.options().price;
        console.log(`Finished dragging ${draggedLine.type} for #${draggedLine.ticket} to ${finalPrice}`);
        if (window.PositionModified) {
            window.PositionModified.postMessage(JSON.stringify({
                ticket: parseInt(draggedLine.ticket),
                type: draggedLine.type.toUpperCase(),
                price: finalPrice
            }));
        }

        chart.applyOptions({ handleScroll: true, handleScale: true });
        container.classList.remove('grabbing');
        isDragging = false;
        draggedLine = null;
        return;
    }

    // 2. Handle Tap (Entry Line)
    if (potentialTapTicket && dist < 10 && (now - dragStartTime) < 500) {
        showContextMenu(endX, endY, potentialTapTicket);
    }

    potentialTapTicket = null;
}

// Touch wrappers
function onTouchStart(e) {
    if (e.touches.length === 1) {
        const touch = e.touches[0];
        // Create mock event with VIEWPORT coordinates (clientX/Y) which onDragStart now uses for startX/Y
        // AND calculate offsetX/Y for hit testing inside onDragStart
        const rect = container.getBoundingClientRect();

        const mockE = {
            clientX: touch.clientX,
            clientY: touch.clientY,
            target: container,
            offsetX: touch.clientX - rect.left,
            offsetY: touch.clientY - rect.top,
            touches: e.touches // Pass touches so onDragStart can fallback if needed
        };

        onDragStart(mockE);

        if (isDragging) {
            e.preventDefault(); // Lock scroll only if we grabbed a line
        }
    }
}

function onTouchMove(e) {
    if (isDragging) {
        e.preventDefault(); // Stop chart panning
        const touch = e.touches[0];
        const rect = container.getBoundingClientRect();
        const mockE = {
            clientX: touch.clientX,
            clientY: touch.clientY,
            offsetX: touch.clientX - rect.left,
            offsetY: touch.clientY - rect.top,
            touches: e.touches
        };
        onDragMove(mockE);
    }
}


function getPriceFromEvent(e) {
    // Need accurate Y coordinate relative to container
    // e.offsetY is usually good for MouseEvent
    // For touches, we rely on the mock event having valid offsetX/Y or calculate it here
    let y = e.offsetY;
    if (y === undefined && e.touches && e.touches[0]) {
        const rect = container.getBoundingClientRect();
        y = e.touches[0].clientY - rect.top;
    }

    // Convert to Price
    return candleSeries.coordinateToPrice(y);
}

// ==========================================
// Bridge Functions
// ==========================================

window.loadHistory = (jsonData) => {
    try {
        const data = JSON.parse(jsonData);
        const mappedData = data.map(d => ({
            time: d.time,
            open: d.open,
            high: d.high,
            low: d.low,
            close: d.close
        }));

        mappedData.sort((a, b) => a.time - b.time);

        candleSeries.setData(mappedData);
        // Show last 100 candles for bigger view (User requested 100)
        chart.timeScale().setVisibleLogicalRange({ from: mappedData.length - 100, to: mappedData.length });

    } catch (e) {
        console.error("Error loading history", e);
    }
};

window.updateCurrentCandle = (jsonData) => {
};

window.updateLastCandle = (time, open, high, low, close) => {
    if (!candleSeries) return;
    candleSeries.update({ time, open, high, low, close });
};


window.updatePositions = (jsonPositions) => {
    try {
        const positions = JSON.parse(jsonPositions);
        const activeTicketIds = new Set(positions.map(p => p.ticket.toString()));

        // 1. Clean up closed positions
        for (const ticket in activeLines) {
            if (!activeTicketIds.has(ticket)) {
                removePositionLines(ticket);
            }
        }

        // 2. Update/Create
        positions.forEach(pos => {
            const ticket = pos.ticket.toString();
            let group = activeLines[ticket];

            // If dragging, don't update from server to avoid jitter
            if (isDragging && draggedLine && draggedLine.ticket.toString() === ticket) {
                return;
            }

            const isBuy = pos.type.toString().toUpperCase().includes("BUY");
            // Colors: Buy=Green (#00cc00 or #4caf50), Sell=Red (#ff4444 or #f44336)
            const entryColor = isBuy ? '#00cc00' : '#ff4444';
            // Use full type from backend if available (e.g. "BUY LIMIT"), else derive
            const typeStr = pos.type ? pos.type.toString().toUpperCase() : (isBuy ? "BUY" : "SELL");
            const ticketDisplay = "#" + ticket.slice(-4);
            const profitStr = (pos.profit !== undefined) ? ` (${pos.profit >= 0 ? '+' : ''}${pos.profit.toFixed(2)})` : '';

            let valuePerPriceUnit = 0;
            const dist = Math.abs(pos.price_current - pos.price_open);
            if (dist > 0.00001) { // Avoid div by zero
                valuePerPriceUnit = Math.abs(pos.profit) / dist;
            }

            if (!group) {
                // CREATE
                group = { sl: null, tp: null, entry: null, data: pos };
                activeLines[ticket] = group;

                // Entry Line
                group.entryLine = candleSeries.createPriceLine({
                    price: pos.price_open,
                    color: entryColor,
                    lineWidth: 1, // Reduced to 1 (Library supports integers 1-4)
                    lineStyle: LightweightCharts.LineStyle.Dashed,
                    axisLabelVisible: true,
                    title: `${typeStr} ${ticketDisplay}${profitStr}`,
                    textColor: entryColor, // Match text to line
                });
            } else {
                group.entryLine.applyOptions({
                    price: pos.price_open,
                    title: `${typeStr} ${ticketDisplay}${profitStr}`,
                    color: entryColor,
                    textColor: entryColor,
                });
                group.data = pos; // Update stored data (current price/profit)
            }

            // Estimate SL/TP Profit
            const getEstProfit = (targetPrice) => {
                if (valuePerPriceUnit === 0) return "";
                const diff = targetPrice - pos.price_open;
                let isWin = false;
                if (isBuy) isWin = diff > 0;
                else isWin = diff < 0;

                const absProfit = Math.abs(diff) * valuePerPriceUnit;
                const sign = isWin ? "+" : "-";
                return ` (${sign}${absProfit.toFixed(2)})`;
            };

            // SL
            if (pos.sl > 0) {
                const slProfitStr = getEstProfit(pos.sl);
                const titleStr = `SL ${ticketDisplay}${slProfitStr}`; // Exact same string as title
                group.slLabelWidth = getTextWidth(titleStr, "bold 10px sans-serif"); // Calc width

                if (!group.sl) {
                    group.sl = candleSeries.createPriceLine({
                        price: pos.sl,
                        color: '#ff4444',
                        lineWidth: 1,
                        lineStyle: LightweightCharts.LineStyle.Solid,
                        axisLabelVisible: true,
                        title: titleStr,
                    });
                } else {
                    group.sl.applyOptions({
                        price: pos.sl,
                        title: titleStr
                    });
                }
            } else if (group.sl) {
                candleSeries.removePriceLine(group.sl);
                group.sl = null;
                group.slLabelWidth = 0;
            }

            // TP
            if (pos.tp > 0) {
                const tpProfitStr = getEstProfit(pos.tp);
                const titleStr = `TP ${ticketDisplay}${tpProfitStr}`;
                group.tpLabelWidth = getTextWidth(titleStr, "bold 10px sans-serif"); // Calc width

                if (!group.tp) {
                    group.tp = candleSeries.createPriceLine({
                        price: pos.tp,
                        color: '#00cc00',
                        lineWidth: 1,
                        lineStyle: LightweightCharts.LineStyle.Solid,
                        axisLabelVisible: true,
                        title: titleStr,
                    });
                } else {
                    group.tp.applyOptions({
                        price: pos.tp,
                        title: titleStr
                    });
                }
            } else if (group.tp) {
                candleSeries.removePriceLine(group.tp);
                group.tp = null;
                group.tpLabelWidth = 0;
            }
        });

    } catch (e) {
        console.error(e);
    }
};

// ... existing code ...

// Helper to measure text width
function getTextWidth(text, font) {
    const canvas = getTextWidth.canvas || (getTextWidth.canvas = document.createElement("canvas"));
    const context = canvas.getContext("2d");
    context.font = font;
    const metrics = context.measureText(text);
    return metrics.width;
}

const overlay = document.getElementById('cancel-buttons-overlay');

function createCancelButton(ticket, type, color, onClick) {
    const btn = document.createElement('div');
    btn.innerText = 'X';
    btn.style.position = 'absolute';
    // right will be set dynamically
    btn.style.color = 'white';
    btn.style.backgroundColor = color;
    btn.style.padding = '0px 4px';
    btn.style.borderRadius = '2px';
    btn.style.fontSize = '9px';
    btn.style.lineHeight = '14px';
    btn.style.height = '14px';
    btn.style.fontWeight = 'bold';
    btn.style.cursor = 'pointer';
    btn.style.pointerEvents = 'auto';
    btn.style.zIndex = '1000';
    btn.dataset.ticket = ticket;
    btn.dataset.type = type;

    btn.onclick = onClick;

    overlay.appendChild(btn);
    return btn;
}

function updateCancelButtons() {
    if (!chart || !candleSeries) return;

    for (const ticket in activeLines) {
        const group = activeLines[ticket];
        if (!group) continue;

        // SL Button
        if (group.sl) {
            if (!group.slBtn) {
                group.slBtn = createCancelButton(ticket, 'SL', '#ff4444', () => {
                    if (window.PositionModified) {
                        window.PositionModified.postMessage(JSON.stringify({ ticket: parseInt(ticket), type: 'SL', price: 0.0 }));
                    }
                });
            }
            const y = candleSeries.priceToCoordinate(group.data.sl);
            if (y !== null) {
                group.slBtn.style.top = (y - 7) + 'px'; // Center vert

                // Calc offset: Axis (~50-60px) + Label Width + Padding
                const labelW = group.slLabelWidth || 60;
                // Approx Axis Width = 55px (default). Add padding.
                const offset = 55 + labelW + 10;
                group.slBtn.style.right = offset + 'px';

                group.slBtn.style.display = 'block';
            } else {
                group.slBtn.style.display = 'none';
            }
        } else if (group.slBtn) {
            group.slBtn.remove();
            group.slBtn = null;
        }

        // TP Button
        if (group.tp) {
            if (!group.tpBtn) {
                group.tpBtn = createCancelButton(ticket, 'TP', '#00cc00', () => {
                    if (window.PositionModified) {
                        window.PositionModified.postMessage(JSON.stringify({ ticket: parseInt(ticket), type: 'TP', price: 0.0 }));
                    }
                });
            }
            const y = candleSeries.priceToCoordinate(group.data.tp);
            if (y !== null) {
                group.tpBtn.style.top = (y - 7) + 'px';

                const labelW = group.tpLabelWidth || 60;
                const offset = 55 + labelW + 10;
                group.tpBtn.style.right = offset + 'px';

                group.tpBtn.style.display = 'block';
            } else {
                group.tpBtn.style.display = 'none';
            }
        } else if (group.tpBtn) {
            group.tpBtn.remove();
            group.tpBtn = null;
        }
    }
}

// Subscribe to move
// Subscription moved to after init
// chart.timeScale().subscribeVisibleTimeRangeChange(updateCancelButtons);
// Also need to hook into resize or price scale changes?
// handleScale override above handles mouse, but we need event listener.
// Simplified: Use the existing sync loop or animation frame?
// Let's add it to the sync loop or call it frequently?
// The chart logic doesn't expose a clean "price scale changed" event easily.
// Best is to update in sync loop or after setVisibleRange.

function removePositionLines(ticket) {
    const group = activeLines[ticket];
    if (group) {
        if (group.entryLine) candleSeries.removePriceLine(group.entryLine);
        if (group.sl) candleSeries.removePriceLine(group.sl);
        if (group.tp) candleSeries.removePriceLine(group.tp);

        if (group.slBtn) group.slBtn.remove();
        if (group.tpBtn) group.tpBtn.remove();

        delete activeLines[ticket];
    }
}

// Add sync loop for smoother updates
function syncLoop() {
    updateCancelButtons();
    requestAnimationFrame(syncLoop);
}

// Init
initChart();
if (chart) {
    chart.timeScale().subscribeVisibleTimeRangeChange(updateCancelButtons);
}
syncLoop();

// Expose internal log helper
window.log = (msg) => console.log(msg);
