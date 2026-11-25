let selectedDrug = null;
let quantity = 1;
let drugs = [];
let npcTolerance = 0.5;
let configBuyQuantity = null;
let configNpcTolerance = null;

window.addEventListener('message', (event) => {
    const data = event.data;
    switch (data.action) {
        case 'openDialog':
            openDialog(data);
            break;
        case 'npcReaction':
            showReaction(data.message, data.success);
            break;
        case 'counterOffer':
            showCounterOffer(data);
            break;
        case 'closeDialog':
            closeDialog();
            break;
    }
});

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        closeDialog();
        fetch(`https://${GetParentResourceName()}/closeDialog`, { method: 'POST', body: JSON.stringify({}) });
    }
});

// Generate NPC's willingness to pay from config tiers
function generateNpcTolerance() {
    if (!configNpcTolerance || configNpcTolerance.length === 0) {
        return 0.35 + Math.random() * 0.3;
    }
    const roll = Math.random();
    let cumulative = 0;
    for (const tier of configNpcTolerance) {
        cumulative += tier.chance;
        if (roll <= cumulative) {
            return tier.min + Math.random() * (tier.max - tier.min);
        }
    }
    // Fallback to last tier
    const last = configNpcTolerance[configNpcTolerance.length - 1];
    return last.min + Math.random() * (last.max - last.min);
}

// Generate NPC buy quantity from config tiers
function generateNpcQuantity(maxAvailable) {
    if (!configBuyQuantity || configBuyQuantity.length === 0) {
        return Math.min(Math.floor(Math.random() * 3) + 1, maxAvailable);
    }
    const roll = Math.random();
    let cumulative = 0;
    let qty = 1;
    for (const tier of configBuyQuantity) {
        cumulative += tier.chance;
        if (roll <= cumulative) {
            qty = Math.floor(Math.random() * (tier.max - tier.min + 1)) + tier.min;
            break;
        }
    }
    return Math.min(qty, maxAvailable);
}

function openDialog(data) {
    drugs = data.drugs;
    configBuyQuantity = data.buyQuantity || null;
    configNpcTolerance = data.npcTolerance || null;
    npcTolerance = generateNpcTolerance();
    document.getElementById('npc-greeting').textContent = data.greeting;
    renderDrugList(data.drugs);
    document.getElementById('dialog-container').classList.remove('hidden');
    document.getElementById('drug-selection').classList.remove('hidden');
    document.getElementById('price-section').classList.add('hidden');
    document.getElementById('reaction-section').classList.add('hidden');
    selectedDrug = null;
    quantity = 1;
}

function renderDrugList(drugs) {
    const list = document.getElementById('drug-list');
    list.innerHTML = '';
    drugs.forEach(drug => {
        const card = document.createElement('div');
        card.className = 'drug-card';
        card.style.setProperty('--card-color', drug.color + '25');
        card.innerHTML = `
            <i class="fas ${drug.icon}" style="color: ${drug.color}"></i>
            <div class="drug-name">${drug.label}</div>
            <div class="drug-qty">x${drug.count}</div>
        `;
        card.addEventListener('click', () => selectDrug(drug));
        list.appendChild(card);
    });
}

// Calculate where on the slider the NPC's max acceptance is
function getNpcMaxPrice(drug) {
    const range = drug.maxPrice - drug.minPrice;
    return Math.floor(drug.minPrice + range * npcTolerance);
}

// Update slider gradient based on NPC tolerance
function updateSliderGradient(drug) {
    const slider = document.getElementById('price-slider');
    const npcMax = getNpcMaxPrice(drug);
    const range = drug.maxPrice - drug.minPrice;

    const greenEnd = Math.max(5, Math.floor(((npcMax * 0.7) - drug.minPrice) / range * 100));
    const yellowMid = Math.max(greenEnd + 5, Math.floor((npcMax - drug.minPrice) / range * 100));
    const redStart = Math.min(yellowMid + 10, 100);

    slider.style.background = `linear-gradient(to right,
        #00e676 0%,
        #00e676 ${greenEnd}%,
        #ffc107 ${yellowMid}%,
        #ff4757 ${redStart}%,
        #ff4757 100%)`;
}

function selectDrug(drug) {
    selectedDrug = drug;
    quantity = generateNpcQuantity(drug.count);

    document.getElementById('drug-selection').classList.add('hidden');
    document.getElementById('price-section').classList.remove('hidden');

    // Update deal card
    const icon = document.getElementById('deal-icon');
    icon.className = 'fas ' + drug.icon;
    icon.style.color = drug.color;
    document.getElementById('selected-drug-name').textContent = drug.label;
    document.getElementById('selected-drug-count').textContent = 'In pocket: ' + drug.count;
    document.getElementById('qty-value').textContent = 'x' + quantity;

    // Setup slider
    const slider = document.getElementById('price-slider');
    slider.min = drug.minPrice;
    slider.max = drug.maxPrice;
    const startPrice = Math.floor(drug.minPrice + (drug.maxPrice - drug.minPrice) * 0.3);
    slider.value = startPrice;
    document.getElementById('price-min').textContent = '$' + drug.minPrice.toLocaleString();
    document.getElementById('price-max').textContent = '$' + drug.maxPrice.toLocaleString();
    document.getElementById('price-value').textContent = startPrice.toLocaleString();

    // Apply gradient
    updateSliderGradient(drug);
    updatePriceColor(startPrice, drug);
}

// Update the price text color based on position
function updatePriceColor(price, drug) {
    const npcMax = getNpcMaxPrice(drug);
    const priceEl = document.querySelector('.price-display');

    if (price <= npcMax * 0.7) {
        priceEl.style.color = '#00e676';
        priceEl.style.textShadow = '0 0 22px rgba(0, 230, 118, 0.35)';
    } else if (price <= npcMax) {
        priceEl.style.color = '#ffc107';
        priceEl.style.textShadow = '0 0 22px rgba(255, 193, 7, 0.35)';
    } else {
        priceEl.style.color = '#ff4757';
        priceEl.style.textShadow = '0 0 22px rgba(255, 71, 87, 0.35)';
    }
}

document.getElementById('price-slider').addEventListener('input', (e) => {
    const val = parseInt(e.target.value);
    document.getElementById('price-value').textContent = val.toLocaleString();
    if (selectedDrug) {
        updatePriceColor(val, selectedDrug);
    }
});

document.getElementById('sell-btn').addEventListener('click', () => {
    if (!selectedDrug) return;
    const price = parseInt(document.getElementById('price-slider').value);
    fetch(`https://${GetParentResourceName()}/sellDrug`, {
        method: 'POST',
        body: JSON.stringify({
            drugId: selectedDrug.id,
            price: price,
            quantity: quantity,
            npcTolerance: npcTolerance,
        }),
    });
    document.getElementById('sell-btn').disabled = true;
    document.getElementById('sell-btn').innerHTML = '<i class="fas fa-spinner fa-spin"></i><span>Waiting...</span>';
});

document.getElementById('close-btn').addEventListener('click', () => {
    closeDialog();
    fetch(`https://${GetParentResourceName()}/closeDialog`, { method: 'POST', body: JSON.stringify({}) });
});

function showCounterOffer(data) {
    document.getElementById('price-section').classList.add('hidden');
    document.getElementById('drug-selection').classList.add('hidden');
    document.getElementById('reaction-section').classList.remove('hidden');

    const iconEl = document.getElementById('reaction-icon');
    iconEl.className = 'reaction-icon counter';
    iconEl.innerHTML = '<i class="fas fa-hand-holding-dollar"></i>';

    var priceLabel = '$' + Number(data.counterPrice).toLocaleString();
    document.getElementById('reaction-text').innerHTML = '<span class="counter-msg">' + data.message + '</span>' +
        '<div class="counter-buttons">' +
        '<button class="counter-btn accept" onclick="respondCounter(true, \'' + data.drugId + '\', ' + data.counterPrice + ', ' + data.quantity + ')"><i class="fas fa-check"></i> 收 ' + priceLabel + '</button>' +
        '<button class="counter-btn reject" onclick="respondCounter(false, \'' + data.drugId + '\', ' + data.counterPrice + ', ' + data.quantity + ')"><i class="fas fa-times"></i> 走數</button>' +
        '</div>';
}

function respondCounter(accept, drugId, counterPrice, qty) {
    if (accept) {
        fetch(`https://${GetParentResourceName()}/acceptCounter`, {
            method: 'POST',
            body: JSON.stringify({ drugId, counterPrice, quantity: qty }),
        });
    } else {
        fetch(`https://${GetParentResourceName()}/rejectCounter`, {
            method: 'POST',
            body: JSON.stringify({ drugId }),
        });
    }
    // Disable buttons
    document.querySelectorAll('.counter-btn').forEach(btn => btn.disabled = true);
}

function showReaction(message, success) {
    document.getElementById('price-section').classList.add('hidden');
    document.getElementById('drug-selection').classList.add('hidden');
    document.getElementById('reaction-section').classList.remove('hidden');

    const iconEl = document.getElementById('reaction-icon');
    if (success) {
        iconEl.className = 'reaction-icon success';
        iconEl.innerHTML = '<i class="fas fa-check"></i>';
    } else {
        iconEl.className = 'reaction-icon failed';
        iconEl.innerHTML = '<i class="fas fa-times"></i>';
    }
    document.getElementById('reaction-text').textContent = message;

    setTimeout(() => {
        closeDialog();
        fetch(`https://${GetParentResourceName()}/closeDialog`, { method: 'POST', body: JSON.stringify({}) });
    }, 2500);
}

function closeDialog() {
    document.getElementById('dialog-container').classList.add('hidden');
    const btn = document.getElementById('sell-btn');
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-handshake"></i><span>Make the deal</span>';
    selectedDrug = null;
    quantity = 1;
}
