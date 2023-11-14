local ModDataHandler = require("TOC/Handlers/ModDataHandler")
local CommonMethods = require("TOC/CommonMethods")
local CachedDataHandler = require("TOC/Handlers/CachedDataHandler")
local StaticData = require("TOC/StaticData")
-----------

-- THIS SHOULD BE LOCAL ONLY! WE'RE MANAGING EVENTS AND INITIALIZATION STUFF!

-- LIST OF STUFF THAT THIS CLASS NEEDS TO DO
-- Keep track of cut limbs so that we don't have to loop through all of them all the time
-- Update current player status (infection checks)
-- handle stats increase\decrease

---@class PlayerHandler
---@field playerObj IsoPlayer
local PlayerHandler = {}

---Setup the Player Handler and modData, only for local client
---@param playerObj IsoPlayer
---@param isForced boolean?
function PlayerHandler.InitializePlayer(playerObj, isForced)
    local username = playerObj:getUsername()
    TOC_DEBUG.print("initializing local player: " .. username)

    ModDataHandler:new(username, isForced)
    PlayerHandler.playerObj = playerObj

    -- Calculate amputated limbs and highest point of amputations at startup
    CachedDataHandler.CalculateAmputatedLimbs(username)
    CachedDataHandler.CalculateHighestAmputatedLimbs(username)

    -- Since isForced is used to reset an existing player data, we're gonna clean their ISHealthPanel table too
    if isForced then
        --ISHealthPanel.highestAmputations = {}
        local ItemsHandler = require("TOC/Handlers/ItemsHandler")
        ItemsHandler.DeleteAllOldAmputationItems(playerObj)
        CachedDataHandler.Reset(username)
    end
end

---Handles the traits
---@param playerObj IsoPlayer
function PlayerHandler.ManageTraits(playerObj)
    local AmputationHandler = require("Handlers/TOC_AmputationHandler")
    for k, v in pairs(StaticData.TRAITS_BP) do
        if playerObj:HasTrait(k) then
            -- Once we find one, we should be done.
            local tempHandler = AmputationHandler:new(v)
            tempHandler:execute(false)      -- No damage
            tempHandler:close()
            return
        end
    end
end

-------------------------
--* Events *--

---Check if the player has an infected (as in, zombie infection) body part
---@param character IsoGameCharacter
function PlayerHandler.CheckInfection(character)
    -- This fucking event barely works. Bleeding seems to be the only thing that triggers it
    if character ~= getPlayer() then return end
    local bd = character:getBodyDamage()
    local modDataHandler = ModDataHandler.GetInstance()

    for i=1, #StaticData.LIMBS_STRINGS do
        local limbName = StaticData.LIMBS_STRINGS[i]
        local bptEnum = StaticData.BODYPARTSTYPES_ENUM[limbName]
        local bodyPart = bd:getBodyPart(bptEnum)

        if bodyPart:bitten() or bodyPart:IsInfected() then
            if modDataHandler:getIsCut(limbName) then
                bodyPart:SetBitten(false)
            else
                modDataHandler:setIsInfected(limbName, true)
            end
        end
    end

    -- Check other body parts that are not included in the mod, if there's a bite there then the player is fucked
    -- We can skip this loop if the player has been infected. The one before we kinda need it to handle correctly the bites in case the player wanna cut stuff off anyway
    if ModDataHandler.GetInstance():getIsIgnoredPartInfected() then return end

    for i=1, #StaticData.IGNORED_PARTS_STRINGS do
        local bodyPartType = BodyPartType[StaticData.IGNORED_PARTS_STRINGS[i]]
        local bodyPart = bd:getBodyPart(bodyPartType)
        if bodyPart and (bodyPart:bitten() or bodyPart:IsInfected()) then
            ModDataHandler.GetInstance():setIsIgnoredPartInfected(true)
        end
    end
end

Events.OnPlayerGetDamage.Add(PlayerHandler.CheckInfection)


--* Events *--
---Updates the cicatrization process, run when a limb has been cut
function PlayerHandler.UpdateCicatrization()
    if ModDataHandler.GetInstance():getIsAnyLimbCut() == false then return end

    -- TODO Update cicatrization
end


------------------------------------------
--* OVERRIDES *--

--* Time to perform actions overrides *--

local og_ISBaseTimedAction_adjustMaxTime = ISBaseTimedAction.adjustMaxTime
--- Adjust time
---@diagnostic disable-next-line: duplicate-set-field
function ISBaseTimedAction:adjustMaxTime(maxTime)
    local time = og_ISBaseTimedAction_adjustMaxTime(self, maxTime)
    local modDataHandler = ModDataHandler.GetInstance()
    if time ~= -1 and modDataHandler and modDataHandler:getIsAnyLimbCut() then
        local pl = getPlayer()
        local amputatedLimbs = CachedDataHandler.GetAmputatedLimbs(pl:getUsername())
        for i=1, #amputatedLimbs do
            local limbName = amputatedLimbs[i]
            if modDataHandler:getIsCut(limbName) then
                local perk = Perks["Side_" .. CommonMethods.GetSide(limbName)]
                local perkLevel = pl:getPerkLevel(perk)
                local perkLevelScaled
                if perkLevel ~= 0 then perkLevelScaled = perkLevel / 10 else perkLevelScaled = 0 end
                time = time * (StaticData.LIMBS_TIME_MULTIPLIER[limbName] - perkLevelScaled)
            end
        end
    end
    return time
end

local og_ISBaseTimedAction_perform = ISBaseTimedAction.perform
--- After each action, level up perks
---@diagnostic disable-next-line: duplicate-set-field
function ISBaseTimedAction:perform()
	og_ISBaseTimedAction_perform(self)

    if ModDataHandler.GetInstance():getIsAnyLimbCut() then
        for side, _ in pairs(StaticData.SIDES_STRINGS) do
            local limbName = "Hand_" .. side
            if ModDataHandler.GetInstance():getIsCut(limbName) then
                PlayerHandler.playerObj:getXp():AddXP(Perks["Side_" .. side], 2)       -- TODO Make it dynamic
            end
        end
    end
end

--* Equipping items overrides *--

local og_ISEquipWeaponAction_isValid = ISEquipWeaponAction.isValid
---Add a condition to check the feasibility of having 2 handed weapons or if both arms are cut off
---@return boolean
function ISEquipWeaponAction:isValid()
    local isValid = og_ISEquipWeaponAction_isValid(self)
    local modDataHandler = ModDataHandler.GetInstance(self.character:getUsername())
    if isValid and modDataHandler:getIsAnyLimbCut() then

        -- TODO We need to consider amputating legs, this won't be correct anymore
        -- TODO Consider prosthesis
        -- TODO Maybe isValid isn't the right choice, we want them to be able to equip weapons nonetheless but one handed
        if modDataHandler:getIsCut("Hand_L") and modDataHandler:getIsCut("Hand_R") then
            isValid = false
        end
    end
    return isValid
end


---@class ISEquipWeaponAction
---@field character IsoPlayer

---comment
---@param modDataHandler ModDataHandler
function ISEquipWeaponAction:performWithAmputation(modDataHandler)
    local hand = nil
    local otherHand = nil
    local getMethodFirst = nil
    local setMethodFirst = nil

    local getMethodSecond = nil
    local setMethodSecond = nil

    if self.primary then
        hand = "Hand_R"
        otherHand = "Hand_L"
        getMethodFirst = self.character.getSecondaryHandItem
        setMethodFirst = self.character.setSecondaryHandItem
        getMethodSecond = self.character.getPrimaryHandItem
        setMethodSecond = self.character.setPrimaryHandItem
    else
        hand = "Hand_L"
        otherHand = "Hand_R"
        getMethodFirst = self.character.getPrimaryHandItem
        setMethodFirst = self.character.setPrimaryHandItem
        getMethodSecond = self.character.getSecondaryHandItem
        setMethodSecond = self.character.setSecondaryHandItem
    end


    if not self.twoHands then
        if getMethodFirst(self.character) and getMethodFirst(self.character):isRequiresEquippedBothHands() then
            setMethodFirst(self.character, nil)
        end
        -- if this weapon is already equiped in the 2nd hand, we remove it
        if(getMethodFirst(self.character) == self.item or getMethodFirst(self.character) == getMethodSecond(self.character)) then
            setMethodFirst(self.character, nil)
        end
        -- if we are equipping a handgun and there is a weapon in the secondary hand we remove it
        if instanceof(self.item, "HandWeapon") and self.item:getSwingAnim() and self.item:getSwingAnim() == "Handgun" then
            if getMethodFirst(self.character) and instanceof(getMethodFirst(self.character), "HandWeapon") then
                setMethodFirst(self.character, nil)
            end
        end
        if not getMethodSecond(self.character) or getMethodSecond(self.character) ~= self.item then
            setMethodSecond(self.character, nil)

            -- TODO We should use the CachedData indexable instead of modDataHandler

            if not modDataHandler:getIsCut(hand) then
                setMethodSecond(self.character, self.item)
            else
                setMethodFirst(self.character, self.item)
            end
        end
    else
        setMethodFirst(self.character, nil)
        setMethodSecond(self.character, nil)

        if not modDataHandler:getIsCut(hand) then
            setMethodSecond(self.character, self.item)
        end

        if not modDataHandler:getIsCut(otherHand) then
            setMethodFirst(self.character, self.item)
        end
    end
    
end

local og_ISEquipWeaponAction_perform = ISEquipWeaponAction.perform
function ISEquipWeaponAction:perform()
    og_ISEquipWeaponAction_perform(self)

    -- TODO Can we do it earlier?
    local modDataHandler = ModDataHandler.GetInstance(self.character:getUsername())

    -- Just check it any limb has been cut. If not, we can just return from here
    if modDataHandler:getIsAnyLimbCut() == true then
        self:performWithAmputation(modDataHandler)
    end
end



-- TODO Limit 2 hands weapons and stuff like that

return PlayerHandler