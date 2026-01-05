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
            },
            grid: {
                vertLines: { color: 'rgba(42, 46, 57, 0.5)' },
                horzLines: { color: 'rgba(42, 46, 57, 0.5)' },
            },
            rightPriceScale: {
                borderColor: 'rgba(197, 203, 206, 0.8)',
            },
            timeScale: {
                borderColor: 'rgba(197, 203, 206, 0.8)',
                timeVisible: true,
                secondsVisible: false,
            },
            crosshair: {
                mode: LightweightCharts.CrosshairMode.Normal,
            },
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

let ghostLine = null; // Temporary line for creation

function onDragStart(e) {
    const price = getPriceFromEvent(e);
    if (price === null) return;

    const clickY = e.offsetY || (e.touches && e.touches[0].clientY);
    let bestMatch = null;
    let minDist = 30; // Increased tolerance for better touch

    // Iterate all active lines
    for (const ticket in activeLines) {
        const group = activeLines[ticket];

        // 1. Check SL (Priority)
        if (group.sl) {
            const lineY = candleSeries.priceToCoordinate(group.sl.options().price);
            if (lineY !== null && Math.abs(lineY - clickY) < minDist) {
                bestMatch = { ticket: ticket, type: 'sl', lineObj: group.sl, isExisting: true };
                break; // Found priority target
            }
        }

        // 2. Check TP (Priority)
        if (group.tp) {
            const lineY = candleSeries.priceToCoordinate(group.tp.options().price);
            if (lineY !== null && Math.abs(lineY - clickY) < minDist) {
                bestMatch = { ticket: ticket, type: 'tp', lineObj: group.tp, isExisting: true };
                break;
            }
        }

        // 3. Check Entry (For Creation)
        if (group.entryLine) {
            const lineY = candleSeries.priceToCoordinate(group.entryLine.options().price);
            if (lineY !== null && Math.abs(lineY - clickY) < minDist) {
                // Use a fallback match, but keep searching for SL/TP in other orders if overlapping
                if (!bestMatch) {
                    bestMatch = { ticket: ticket, type: 'create', lineObj: group.entryLine, data: group.data, isExisting: false };
                }
            }
        }
    }

    if (bestMatch) {
        isDragging = true;
        draggedLine = bestMatch;
        chart.applyOptions({ handleScroll: false, handleScale: false });
        container.classList.add('grabbing');

        // If creating new SL/TP, spawn a ghost line
        if (!draggedLine.isExisting) {
            ghostLine = candleSeries.createPriceLine({
                price: price,
                color: '#d1d4dc',
                lineWidth: 2,
                lineStyle: LightweightCharts.LineStyle.Dotted,
                axisLabelVisible: true,
                title: 'Drag to set SL/TP',
            });
        }
    }
}

function onDragMove(e) {
    if (!isDragging || !draggedLine) return;

    const price = getPriceFromEvent(e);
    if (price) {
        if (draggedLine.isExisting) {
            // Move existing line
            draggedLine.lineObj.applyOptions({ price: price });
        } else {
            // Move Ghost Line & Update Logic
            if (ghostLine) {
                ghostLine.applyOptions({ price: price });

                // Determine SL vs TP
                const entryPrice = draggedLine.data.price_open; // Ensure we use updated key
                const isBuy = draggedLine.data.type.toString().toUpperCase().includes("BUY");

                // Logic:
                // BUY: Below = SL, Above = TP
                // SELL: Above = SL, Below = TP

                let isSL = false;
                if (isBuy) {
                    isSL = price < entryPrice;
                } else {
                    isSL = price > entryPrice;
                }

                const typeStr = isSL ? "SL" : "TP";
                const color = isSL ? '#ff4444' : '#00cc00';

                ghostLine.applyOptions({
                    title: `${typeStr} #${draggedLine.ticket}`,
                    color: color
                });

                // Store inferred type for End event
                draggedLine.inferredType = typeStr;
            }
        }
    }
}

function onDragEnd(e) {
    if (isDragging && draggedLine) {
        let finalPrice = 0;
        let type = '';

        if (draggedLine.isExisting) {
            finalPrice = draggedLine.lineObj.options().price;
            type = draggedLine.type;
        } else if (ghostLine && draggedLine.inferredType) {
            finalPrice = ghostLine.options().price;
            type = draggedLine.inferredType;

            // Remove ghost
            candleSeries.removePriceLine(ghostLine);
            ghostLine = null;
        }

        if (type) {
            console.log(`Finished dragging ${type} for #${draggedLine.ticket} to ${finalPrice}`);
            if (window.PositionModified) {
                window.PositionModified.postMessage(JSON.stringify({
                    ticket: parseInt(draggedLine.ticket),
                    type: type.toUpperCase(),
                    price: finalPrice
                }));
            }
        }

        chart.applyOptions({ handleScroll: true, handleScale: true });
        container.classList.remove('grabbing');
    }

    isDragging = false;
    draggedLine = null;
    if (ghostLine) {
        candleSeries.removePriceLine(ghostLine);
        ghostLine = null;
    }
}

// Touch wrappers
function onTouchStart(e) {
    if (e.touches.length === 1) {
        // Only drag if single touch.
        // We modify the event to look like mouse event or adapt onDragStart
        // e.preventDefault(); // Stop scroll? Warning: this stops ALL scroll.
        // Better: hit test first, THEN prevent default if hit.

        const touch = e.touches[0];
        // Mock simple object for getPriceFromEvent
        const mockE = {
            clientX: touch.clientX,
            clientY: touch.clientY,
            target: container,
            // Native touch support in lightweight-charts for coordinate conversion?
            // we need to calculate offsetX/Y carefully.
            offsetX: touch.clientX - container.getBoundingClientRect().left,
            offsetY: touch.clientY - container.getBoundingClientRect().top
        };

        onDragStart({ ...mockE, touches: e.touches });

        if (isDragging) {
            e.preventDefault(); // Lock scroll only if we grabbed a line
        }
    }
}

function onTouchMove(e) {
    if (isDragging) {
        e.preventDefault(); // Stop chart panning
        const touch = e.touches[0];
        const mockE = {
            offsetX: touch.clientX - container.getBoundingClientRect().left,
            offsetY: touch.clientY - container.getBoundingClientRect().top
        };
        onDragMove(mockE);
    }
}


function getPriceFromEvent(e) {
    // Need accurate Y coordinate relative to container
    // e.offsetY is usually good for MouseEvent
    let y = e.offsetY;
    if (y === undefined && e.touches) {
        // Fallback for touch logic passed above if needed
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
        // Map to TV format: { time: 'yyyy-mm-dd' or timestamp, open, high, low, close }
        // Incoming data has { time: 172... (seconds), open... }
        // TV supports unix timestamp (seconds) if we use time as object { type: 'custom'?? } OR just seconds.
        // Standard TV time is seconds.

        const mappedData = data.map(d => ({
            time: d.time, // Ensure this is seconds
            open: d.open,
            high: d.high,
            low: d.low,
            close: d.close
        }));

        // Sort just in case
        mappedData.sort((a, b) => a.time - b.time);

        candleSeries.setData(mappedData);
        chart.timeScale().fitContent();

    } catch (e) {
        console.error("Error loading history", e);
    }
};

window.updateCurrentCandle = (jsonData) => {
    // Not used directly? OR used for single candle update.
    // Implementing simple update
};

// We will use a simpler tick update or direct modification
window.updateLastCandle = (time, open, high, low, close) => {
    if (!candleSeries) return;
    candleSeries.update({ time, open, high, low, close });
};


window.updatePositions = (jsonPositions) => {
    try {
        const positions = JSON.parse(jsonPositions);
        const activeTicketIds = new Set(positions.map(p => p.ticket.toString())); // Use string for keys

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

            // Logic: If already dragging this exact ticket, SKIP update to prevent jitter
            if (isDragging && draggedLine && draggedLine.ticket.toString() === ticket) {
                return;
            }

            const isBuy = pos.type.toString().toUpperCase().includes("BUY");
            const color = isBuy ? '#2196F3' : '#F44336';

            if (!group) {
                // CREATE
                group = { sl: null, tp: null, entry: null, data: pos };
                activeLines[ticket] = group;

                // Entry Line
                group.entryLine = candleSeries.createPriceLine({
                    price: pos.price_open,
                    color: color,
                    lineWidth: 1,
                    lineStyle: LightweightCharts.LineStyle.Dashed,
                    axisLabelVisible: true,
                    title: `Order #${ticket}`,
                });
            } else {
                // UPDATE Entry (usually static but good to sync)
                group.entryLine.applyOptions({ price: pos.price_open });
            }

            // SL
            if (pos.sl > 0) {
                if (!group.sl) {
                    group.sl = candleSeries.createPriceLine({
                        price: pos.sl,
                        color: '#ff4444',
                        lineWidth: 2,
                        lineStyle: LightweightCharts.LineStyle.Solid,
                        axisLabelVisible: true,
                        title: `SL`,
                    });
                } else {
                    group.sl.applyOptions({ price: pos.sl });
                }
            } else if (group.sl) {
                candleSeries.removePriceLine(group.sl);
                group.sl = null;
            }

            // TP
            if (pos.tp > 0) {
                if (!group.tp) {
                    group.tp = candleSeries.createPriceLine({
                        price: pos.tp,
                        color: '#00cc00',
                        lineWidth: 2,
                        lineStyle: LightweightCharts.LineStyle.Solid,
                        axisLabelVisible: true,
                        title: `TP`,
                    });
                } else {
                    group.tp.applyOptions({ price: pos.tp });
                }
            } else if (group.tp) {
                candleSeries.removePriceLine(group.tp);
                group.tp = null;
            }
        });

    } catch (e) {
        console.error(e);
    }
};

function removePositionLines(ticket) {
    const group = activeLines[ticket];
    if (group) {
        if (group.entryLine) candleSeries.removePriceLine(group.entryLine);
        if (group.sl) candleSeries.removePriceLine(group.sl);
        if (group.tp) candleSeries.removePriceLine(group.tp);
        delete activeLines[ticket];
    }
}

// Init
initChart();

// Expose internal log helper
window.log = (msg) => console.log(msg);

