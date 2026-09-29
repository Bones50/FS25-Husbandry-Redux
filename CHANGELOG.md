# CHANGELOG

Changelog Last updated: 29/09/2026
<h2><b>V0.0.0.1 - Pre-Release Test Version</b></h2>

FIXED
1) Barns with feeding robots now work correctly

ADDED
1) Mod renamed to Husbandry Redux
2) Herd advisor has been rewritten from the ground up to operate of off breeds rather than animal groups. The Herd adviser will now give you an indication of food requirements, barn size requirements and production requirements, with the aim of maximising the profitability of that barn. For example if your animals are at 100% health it will reccommend cheaper foods that will keep them at 100% and reduce input costs to maximise profitablility. the herd adviser will set a default breed type (Producer/Breeder) and use that to work out the best approach to maximising profit (e.g. breeder farms will focus on best time to sell, producers will focus on maximising sell value of the products).
3) UI completely rewritten to reflect the updated redux UI approach. You can see each animal type using the tabs across at the top of the page.
4) Added the Husbandry Redux overview pages (Animals Groups OR Breeds view). Will give you and overview of all the animals on your farm and includes reccomendations from the her adviser.
5) Buy and sell orders now fully implemented and working. You can set how many, how often, when to start and how many months to sell for.
6) Advanced Feeding can be swicthed on and off per barn (i.e. letting HR determine optimal food mix and request that from DR rather than the DR default)

<h2><b>V0.0.0.1 - Pre-Release Test Version</b></h2>

FEATURES
1) Advanced animal feeder - Takes into account animals that require ratio's of food and supplies that to the distribution redux mod as demand rather than the default demand. Where possible DR will supply all relevant foods at the require proportions to ensure 100% health. NOTE: Requires Distribution Redux to be installed for this to work.
2) Barn/Herd Inspector - Allows you to view the status of all animals in one view, as well as the status of each barn in detail. 
3) Herd Adviser - montior animals/barns, provides advice and embeds it in the Barn/Herd Inspector. Examples would be No room for new births, sell animals to make space, or add root crops to the horse barn to maximise health/value, or animals have passed their prime and are losing value so sell them. 
4) Animal Buy/Sell - replaces the default game buy/sell screens so you can do it all from directly within the mod.
5) Animal AutoTrader - Allows a user to place buy orders and sell orders for animals over time (e.g. buy/Sell X Cows, every Y Months for Z Months) per barn.
6) UI - Added a new tab for husbandry redux to the Distribution Redux page and embedded additional details in the DR Animal Husbandry UI.
7) Multilingual Support - Pre built with l10n support.

Known Issues
1) Advanced Animal feeding is not working with Barns with an autofeeder - currently being worked on
2) Herd Adviser - Some issues with the advice given due to not enough granularity in the animal data - currently being worked on
3) Animal Auto-Trader - Same granularity issue above applies to the autotrader, have turned it off in the settings for now while i rebuild. You can reactivate but at best it will not work as intended, and at worst it may mess with your animals in unintended ways.

WIP Features
1) Manure for all Barns
2) Remove dependency on Distribution Redux
