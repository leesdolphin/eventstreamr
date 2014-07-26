/* 
 * To change this license header, choose License Headers in Project Properties.
 * To change this template file, choose Tools | Templates
 * and open the template in the editor.
 */

var shortEventDuration = 100

$(document).ready(function() {
    $("#main-footer").click(function() {
        $(this).contents().fadeOut(shortEventDuration).promise().done(function() {
            isShowMore = $("#main-footer").hasClass("show-more");
            console.log(isShowMore);
            if (isShowMore) {
                $("#main-footer").addClass("show-less");
                $("#main-footer").removeClass("show-more");
                $("#footer-text").text("Show Less");
                transformToSmallHeader();
            } else {
                $("#main-footer").removeClass("show-less");
                $("#main-footer").addClass("show-more");
                $("#footer-text").text("Show More");
                transformToLargeHeader();
            }
            $(this).fadeIn(shortEventDuration);
        });






    });


});


function transformToSmallHeader() {
    $("#main-panel").removeClass("hide-overview")
    $("#main-panel").addClass("show-overview")

}

function transformToLargeHeader() {
//    $(function() {
//        $("#overview").animate({
//            height: 0,
//            opacity: 0
//        }, {duration: 200, queue: false, complete: function() {$(this).hide();}});
//        $("#front-panel").animate({
//            height: "100%",
//            
//        }, {duration: 200, queue: false});
//    });
    $("#main-panel").addClass("hide-overview")
    $("#main-panel").removeClass("show-overview")
}