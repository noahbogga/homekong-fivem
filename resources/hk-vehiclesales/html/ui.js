HKVehicleSales = {}

$(document).ready(function(){
    $('.sell-container').hide();
    $('.buy-container').hide();

    window.addEventListener('message', function(event){
        var eventData = event.data;

        if (eventData.action == "sellVehicle") {
            $('.sell-container').fadeIn(150);
            HKVehicleSales.setupSellContract(eventData)
        }

        if (eventData.action == "buyVehicle") {
            $('.buy-container').fadeIn(150);
            HKVehicleSales.setupBuyContract(eventData, eventData.vehicleData)
        }
    });
});

$(document).on('keydown', function() {
    switch(event.keyCode) {
        case 27:
            $('.sell-container').fadeOut(100);
            $('.buy-container').fadeOut(100);
            $.post('https://hk-vehiclesales/close');
            break;
    }
});

$(document).on('click', '#sell-vehicle', function(){
    if ($('.vehicle-sell-price').val() != "") {
        if (!isNaN($('.vehicle-sell-price').val())) {
            $.post('https://hk-vehiclesales/sellVehicle', JSON.stringify({
                price: $('.vehicle-sell-price').val(),
                desc: $('.vehicle-description').val()
            }));
        
            $('.sell-container').fadeOut(100);
            $.post('https://hk-vehiclesales/close');
        } else {
            $.post('https://hk-vehiclesales/error', JSON.stringify({
                message: "Amount must be numbers.."
            }))
        }
    } else {
        $.post('https://hk-vehiclesales/error', JSON.stringify({
            message: "Enter an amount.."
        }))
    }
});

$(document).on('click', '#buy-vehicle', function(){
    $.post('https://hk-vehiclesales/buyVehicle');
    $('.buy-container').fadeOut(100);
    $.post('https://hk-vehiclesales/close');
});

HKVehicleSales.setupSellContract = function(data) {
    $("#seller-name").html(data.sellerData.firstname + " " + data.sellerData.lastname);
    $("#seller-banknr").html(data.sellerData.account);
    $("#seller-telnr").html(data.sellerData.phone);
    $("#vehicle-plate").html(data.plate);
}

HKVehicleSales.setupBuyContract = function(data, vData) {
    $("#buy-seller-name").html(data.sellerData.firstname + " " + data.sellerData.lastname);
    $("#buy-seller-banknr").html(data.sellerData.account);
    $("#buy-seller-telnr").html(data.sellerData.phone);
    $("#buy-vehicle-plate").html(data.plate);
    $("#buy-vehicle-desc").html(vData.desc);
    $("#buy-price").html("&dollar;" + vData.price);
}

function calculatePrice() {
    var priceVal = $('.vehicle-sell-price').val();
    
    $('#tax').html("&dollar; " + (priceVal / 100 * 19).toFixed(0));
    $('#mosley-cut').html("&dollar; " + (priceVal / 100 * 4).toFixed(0));
    $('#total-money').html("&dollar; " + (priceVal / 100 * 77).toFixed(0));
}