local DataController = require("TOC/Controllers/DataController")
local CommonMethods = require("TOC/CommonMethods")
local CachedDataHandler = require("TOC/Handlers/CachedDataHandler")
local StaticData = require("TOC/StaticData")
-----------

-- THIS SHOULD BE LOCAL ONLY! WE'RE MANAGING EVENTS AND INITIALIZATION STUFF!

-- LIST OF STUFF THAT THIS CLASS NEEDS TO DO
-- Keep track of cut limbs so that we don't have to loop through all of them all the time
-- Update current player status (infection checks)
-- handle stats increase\decrease

---@class LocalPlayerController
---@field playerObj IsoPlayer
---@field username string
---@field hasBeenDamaged boolean
local LocalPlayerController = {}

---Setup the Player Handler and modData, only for local client
---@param isForced boolean?
function LocalPlayerController.InitializePlayer(isForced)
    local playerObj = getPlayer()
    local username = playerObj:getUsername()

    TOC_DEBUG.print("Initializing local player: " .. username)

    DataController:new(username, isForced)
    LocalPlayerController.playerObj = playerObj
    LocalPlayerController.username = username

    -- Calculate amputated limbs and highest point of amputations at startup
    --CachedDataHandler.CalculateAmputatedLimbs(username)
    --CachedDataHandler.CalculateHighestAmputatedLimbs(username)

    --Setup the CicatrizationUpdate event and triggers it once
    Events.OnAmputatedLimb.Add(LocalPlayerController.ToggleUpdateAmputations)
    LocalPlayerController.ToggleUpdateAmputations()

    -- Since isForced is used to reset an existing player data, we're gonna clean their ISHealthPanel table too
    if isForced then
        local ItemsController = require("TOC/Controllers/ItemsController")
        ItemsController.Player.DeleteAllOldAmputationItems(playerObj)
        CachedDataHandler.Reset(username)
    end

    -- Set a bool to use an overriding GetDamagedParts
    SetHealthPanelTOC()

end

---Handles the traits
---@param playerObj IsoPlayer
function LocalPlayerController.ManageTraits(playerObj)
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

--* Health management *--

---Used to heal an area that has been cut previously. There's an exception for bites, those are managed differently
---@param bodyPart BodyPart
function LocalPlayerController.HealArea(bodyPart)

    bodyPart:setFractureTime(0)

    bodyPart:setScratched(false, true)
    bodyPart:setScratchTime(0)

    bodyPart:setBleeding(false)
    bodyPart:setBleedingTime(0)

    bodyPart:SetBitten(false)
    bodyPart:setBiteTime(0)

    bodyPart:setCut(false)
    bodyPart:setCutTime(0)

    bodyPart:setDeepWounded(false)
    bodyPart:setDeepWoundTime(0)

    bodyPart:setHaveBullet(false, 0)
    bodyPart:setHaveGlass(false)
    bodyPart:setSplint(false, 0)
end

---comment
---@param bodyDamage BodyDamage
---@param bodyPart BodyPart
---@param limbName string
---@param dcInst DataController
function LocalPlayerController.HealZombieInfection(bodyDamage, bodyPart, limbName, dcInst)
    if bodyDamage:isInfected() == false then return end

    bodyDamage:setInfected(false)
    bodyDamage:setInfectionMortalityDuration(-1)
    bodyDamage:setInfectionTime(-1)
    bodyDamage:setInfectionLevel(-1)
    bodyPart:SetInfected(false)

    dcInst:setIsInfected(limbName, false)
    dcInst:apply()
end

---comment
---@param character IsoPlayer
---@param limbName string
function LocalPlayerController.TryRandomBleed(character, limbName)
    -- Chance should be determined by the cicatrization time
    local cicTime = DataController.GetInstance():getCicatrizationTime(limbName)
    if cicTime == 0 then return end

    -- TODO This is just a placeholder, we need to figure out a better way to calculate this chance
    local normCicTime = CommonMethods.Normalize(cicTime, 0, StaticData.LIMBS_CICATRIZATION_TIME_IND_NUM[limbName])/2
    TOC_DEBUG.print("OG cicTime: " .. tostring(cicTime))
    TOC_DEBUG.print("Normalized cic time : " .. tostring(normCicTime))

    local chance = ZombRandFloat(0.0, 1.0)
    if chance > normCicTime then
        TOC_DEBUG.print("Triggered bleeding from non cicatrized wound")
        local adjacentBodyPartType = BodyPartType[StaticData.LIMBS_ADJACENT_IND_STR[limbName]]
        character:getBodyDamage():getBodyPart(adjacentBodyPartType):setBleeding(true)
        character:getBodyDamage():getBodyPart(adjacentBodyPartType):setBleedingTime(20)
    end
end
-------------------------
--* Events *--
--- Locks OnPlayerGetDamage event, to prevent it from getting spammed constantly
LocalPlayerController.hasBeenDamaged = false


---Check if the player has in infected body part or if they have been hit in a cut area
---@param character IsoPlayer
function LocalPlayerController.HandleDamage(character)
    -- TOC_DEBUG.print("Player got hit!")
    -- TOC_DEBUG.print(damageType)
    if character ~= getPlayer() then return end
    local bd = character:getBodyDamage()
    local dcInst = DataController.GetInstance()
    local modDataNeedsUpdate = false
    for i=1, #StaticData.LIMBS_STR do
        local limbName = StaticData.LIMBS_STR[i]
        local bptEnum = StaticData.BODYLOCS_IND_BPT[limbName]
        local bodyPart = bd:getBodyPart(bptEnum)
        if dcInst:getIsCut(limbName) then

            -- Generic injury, let's heal it since they already cut the limb off
            if bodyPart:HasInjury() then
                TOC_DEBUG.print("Healing area - " .. limbName)
                LocalPlayerController.HealArea(bodyPart)
            end

            -- Special case for bites\zombie infections
            if bodyPart:IsInfected() then
                TOC_DEBUG.print("Healed from zombie infection - " .. limbName)
                LocalPlayerController.HealZombieInfection(bd, bodyPart, limbName, dcInst)
            end
        else
            if bodyPart:bitten() or bodyPart:IsInfected() then
                dcInst:setIsInfected(limbName, true)
                modDataNeedsUpdate = true
            end
        end
    end

    -- Check other body parts that are not included in the mod, if there's a bite there then the player is fucked
    -- We can skip this loop if the player has been infected. The one before we kinda need it to handle correctly the bites in case the player wanna cut stuff off anyway
    if dcInst:getIsIgnoredPartInfected() then return end

    for i=1, #StaticData.IGNORED_BODYLOCS_BPT do
        local bodyPartType = StaticData.IGNORED_BODYLOCS_BPT[i]
        local bodyPart = bd:getBodyPart(bodyPartType)
        if bodyPart and (bodyPart:bitten() or bodyPart:IsInfected()) then
            dcInst:setIsIgnoredPartInfected(true)
            modDataNeedsUpdate = true
        end
    end

    -- TODO in theory  should sync modData, but it's gonna be expensive as fuck. Figure it out
    if modDataNeedsUpdate then
        dcInst:apply()
    end

    -- Disable the lock
    LocalPlayerController.hasBeenDamaged = false

end

---Setup HandleDamage, triggered by OnPlayerGetDamage
---@param character IsoGameCharacter
---@param damageType string
---@param damageAmount number
function LocalPlayerController.OnGetDamage(character, damageType, damageAmount)

    -- TODO Check if other players in the online triggers this

    if LocalPlayerController.hasBeenDamaged == false then
        -- Start checks

        -- TODO Add a timer before we can re-enable this bool?
        LocalPlayerController.hasBeenDamaged = true
        LocalPlayerController.HandleDamage(character)
    end
end

Events.OnPlayerGetDamage.Add(LocalPlayerController.OnGetDamage)

---Updates the cicatrization process, run when a limb has been cut. Run it every 1 hour
function LocalPlayerController.UpdateAmputations()
    local dcInst = DataController.GetInstance()
    if dcInst:getIsAnyLimbCut() == false then
        Events.EveryHours.Remove(LocalPlayerController.UpdateAmputations)
    end

    local pl = LocalPlayerController.playerObj
    local visual = pl:getHumanVisual()
    local amputatedLimbs = CachedDataHandler.GetAmputatedLimbs(pl:getUsername())
    local needsUpdate = false

    for k, _ in pairs(amputatedLimbs) do
        local limbName = k
        local isCicatrized = dcInst:getIsCicatrized(limbName)

        if not isCicatrized then
            needsUpdate = true
            local cicTime = dcInst:getCicatrizationTime(limbName)
            TOC_DEBUG.print("Updating cicatrization for " .. tostring(limbName))

            --* Dirtyness of the wound

            -- We need to get the BloodBodyPartType to find out how dirty the zone is
            local bbptEnum = BloodBodyPartType[limbName]
            local modifier = 0.01 * SandboxVars.TOC.WoundDirtynessMultiplier

            local dirtynessVis = visual:getDirt(bbptEnum) + visual:getBlood(bbptEnum)
            local dirtynessWound = dcInst:getWoundDirtyness(limbName) + modifier

            local dirtyness = dirtynessVis + dirtynessWound

            if dirtyness > 1 then
                dirtyness = 1
            end

            dcInst:setWoundDirtyness(limbName, dirtyness)
            TOC_DEBUG.print("Dirtyness for this zone: " .. tostring(dirtyness))

            --* Cicatrization

            local cicDec = SandboxVars.TOC.CicatrizationSpeed - dirtyness
            if cicDec <= 0 then cicDec = 0.1 end
            cicTime = cicTime - cicDec


            dcInst:setCicatrizationTime(limbName, cicTime)
            TOC_DEBUG.print("New cicatrization time: " .. tostring(cicTime))
            if cicTime <= 0 then
                TOC_DEBUG.print(tostring(limbName) .. " is cicatrized")
                dcInst:setIsCicatrized(limbName, true)
            end
        end
    end

    if needsUpdate then
        TOC_DEBUG.print("updating modData from cicatrization loop")
        dcInst:apply()      -- TODO This is gonna be heavy. Not entirely sure
    else
        TOC_DEBUG.print("Removing UpdateAmputations")
        Events.EveryHours.Remove(LocalPlayerController.UpdateAmputations)     -- We can remove it safely, no cicatrization happening here boys
    end
    TOC_DEBUG.print("updating cicatrization and wound dirtyness!")

end

---Starts safely the loop to update cicatrzation
function LocalPlayerController.ToggleUpdateAmputations()
    TOC_DEBUG.print("Activating amputation handling loop (if it wasn't active before)")
    CommonMethods.SafeStartEvent("EveryHours", LocalPlayerController.UpdateAmputations)
end


--* Helper functions for overrides *--

local function CheckHandFeasibility(limbName)
    local dcInst = DataController.GetInstance()

    return not dcInst:getIsCut(limbName) or dcInst:getIsProstEquipped(StaticData.LIMBS_TO_PROST_GROUP_MATCH_IND_STR[limbName])
end

------------------------------------------
--* OVERRIDES *--

--* Time to perform actions overrides *--

local og_ISBaseTimedAction_adjustMaxTime = ISBaseTimedAction.adjustMaxTime
--- Adjust time
---@diagnostic disable-next-line: duplicate-set-field
function ISBaseTimedAction:adjustMaxTime(maxTime)
    local time = og_ISBaseTimedAction_adjustMaxTime(self, maxTime)

    -- Exceptions handling, if we find that parameter then we just use the original time
    local queue = ISTimedActionQueue.getTimedActionQueue(getPlayer())
    if queue and queue.current and queue.current.skipTOC then return time end

    -- Action is valid, check if we have any cut limb and then modify maxTime
    local dcInst = DataController.GetInstance()
    if time ~= -1 and dcInst and dcInst:getIsAnyLimbCut() then
        local pl = getPlayer()
        local amputatedLimbs = CachedDataHandler.GetAmputatedLimbs(pl:getUsername())

        for k, _ in pairs(amputatedLimbs) do
            local limbName = k
            --if dcInst:getIsCut(limbName) then
            local perk = Perks["Side_" .. CommonMethods.GetSide(limbName)]
            local perkLevel = pl:getPerkLevel(perk)
            local perkLevelScaled
            if perkLevel ~= 0 then perkLevelScaled = perkLevel / 10 else perkLevelScaled = 0 end
            time = time * (StaticData.LIMBS_TIME_MULTIPLIER_IND_NUM[limbName] - perkLevelScaled)
            --end
        end
    end
    return time
end


--* Random bleeding during cicatrization + Perks leveling override *--
local og_ISBaseTimedAction_perform = ISBaseTimedAction.perform
--- After each action, level up perks
---@diagnostic disable-next-line: duplicate-set-field
function ISBaseTimedAction:perform()
	og_ISBaseTimedAction_perform(self)

    local dcInst = DataController.GetInstance()
    if not dcInst:getIsAnyLimbCut() then return end

    local amputatedLimbs = CachedDataHandler.GetAmputatedLimbs(LocalPlayerController.username)
    for k, _ in pairs(amputatedLimbs) do
        local limbName = k
        if dcInst:getIsCut(limbName) then
            local side = CommonMethods.GetSide(limbName)
            LocalPlayerController.playerObj:getXp():AddXP(Perks["Side_" .. side], 1)       -- TODO Make it dynamic
            local prostGroup = StaticData.LIMBS_TO_PROST_GROUP_MATCH_IND_STR[limbName]
            if not dcInst:getIsCicatrized(limbName) and dcInst:getIsProstEquipped(prostGroup) then
                TOC_DEBUG.print("Trying for bleed, player met the criteria")
                -- TODO If we have cut a forearm, it will try to check the hand too, with cicatrization time = 0. We should skip this
                LocalPlayerController.TryRandomBleed(self.character, limbName)
            end
        end
    end
end

--* Equipping items overrides *--

local primaryHand = StaticData.PARTS_IND_STR.Hand .. "_" .. StaticData.SIDES_IND_STR.R
local secondaryHand = StaticData.PARTS_IND_STR.Hand .. "_" .. StaticData.SIDES_IND_STR.L


local og_ISEquipWeaponAction_isValid = ISEquipWeaponAction.isValid
---Add a condition to check the feasibility of having 2 handed weapons or if both arms are cut off
---@return boolean
---@diagnostic disable-next-line: duplicate-set-field
function ISEquipWeaponAction:isValid()
    local isValid = og_ISEquipWeaponAction_isValid(self)
    local dcInst = DataController.GetInstance(self.character:getUsername())
    if isValid and dcInst:getIsAnyLimbCut() then
        local isPrimaryHandValid = CheckHandFeasibility(primaryHand)
        local isSecondaryHandValid = CheckHandFeasibility(secondaryHand)

        --TOC_DEBUG.print("isPrimaryHandValid: " .. tostring(isPrimaryHandValid))
        --TOC_DEBUG.print("isSecondaryHandValid: " .. tostring(isSecondaryHandValid))

        -- Both hands are cut off, so it's impossible to equip in any way
        if not isPrimaryHandValid and not isSecondaryHandValid then
            --TOC_DEBUG.print("Both hands invalid")
            isValid = false
        end
    end
    --     -- Equip primary and no right hand (with no prost)
    --     if self.jobType:contains(equipPrimaryText) and not isPrimaryHandValid then
    --         --TOC_DEBUG.print("Equip primary, no right hand, not valid")
    --         isValid = false
    --     end

    --     -- Equip secondary and no left hand (with no prost)
    --     if self.jobType:contains(equipSecondaryText) and not isSecondaryHandValid then
    --         --TOC_DEBUG.print("Equip secondary, no left hand, not valid")
    --         isValid = false
    --     end
    -- end

    --TOC_DEBUG.print("isValid to return -> " .. tostring(isValid))
    --print("_________________________________")
    return isValid
end


---@class ISEquipWeaponAction
---@field character IsoPlayer

---A recreation of the original method, but with amputations in mind
---@param dcInst DataController
function ISEquipWeaponAction:performWithAmputation(dcInst)
    local hand = nil
    local otherHand = nil
    local getMethodFirst = nil
    local setMethodFirst = nil
    local getMethodSecond = nil
    local setMethodSecond = nil

    if self.primary then
        hand = StaticData.LIMBS_IND_STR.Hand_R
        otherHand = StaticData.LIMBS_IND_STR.Hand_L
        getMethodFirst = self.character.getSecondaryHandItem
        setMethodFirst = self.character.setSecondaryHandItem
        getMethodSecond = self.character.getPrimaryHandItem
        setMethodSecond = self.character.setPrimaryHandItem
    else
        hand = StaticData.LIMBS_IND_STR.Hand_L
        otherHand = StaticData.LIMBS_IND_STR.Hand_R
        getMethodFirst = self.character.getPrimaryHandItem
        setMethodFirst = self.character.setPrimaryHandItem
        getMethodSecond = self.character.getSecondaryHandItem
        setMethodSecond = self.character.setSecondaryHandItem
    end


    if not self.twoHands then
        if getMethodFirst(self.character) and getMethodFirst(self.character):isRequiresEquippedBothHands() then
            setMethodFirst(self.character, nil)
        -- if this weapon is already equiped in the 2nd hand, we remove it
        elseif (getMethodFirst(self.character) == self.item or getMethodFirst(self.character) == getMethodSecond(self.character)) then
            setMethodFirst(self.character, nil)
        -- if we are equipping a handgun and there is a weapon in the secondary hand we remove it
        elseif instanceof(self.item, "HandWeapon") and self.item:getSwingAnim() and self.item:getSwingAnim() == "Handgun" then
            if getMethodFirst(self.character) and instanceof(getMethodFirst(self.character), "HandWeapon") then
                setMethodFirst(self.character, nil)
            end
        else
            setMethodSecond(self.character, nil)
            -- TODO We should use the CachedData indexable instead of dcInst

            if not dcInst:getIsCut(hand) then
                setMethodSecond(self.character, self.item)
                -- Check other HAND!
            elseif not dcInst:getIsCut(otherHand) then
                setMethodFirst(self.character, self.item)
            end
        end

    else
        setMethodFirst(self.character, nil)
        setMethodSecond(self.character, nil)


        local isFirstValid = CheckHandFeasibility(hand)
        local isSecondValid = CheckHandFeasibility(otherHand)
        -- TOC_DEBUG.print("First Hand: " .. tostring(hand))
        -- TOC_DEBUG.print("Prost Group: " .. tostring(prostGroup))
        -- TOC_DEBUG.print("Other Hand: " .. tostring(otherHand))
        -- TOC_DEBUG.print("Other Prost Group: " .. tostring(otherProstGroup))

        -- TOC_DEBUG.print("isPrimaryHandValid: " .. tostring(isFirstValid))
        -- TOC_DEBUG.print("isSecondaryHandValid: " .. tostring(isSecondValid))


        if isFirstValid then
            setMethodSecond(self.character, self.item)
        end

        if isSecondValid then
            setMethodFirst(self.character, self.item)
        end
    end
end

local og_ISEquipWeaponAction_perform = ISEquipWeaponAction.perform
---@diagnostic disable-next-line: duplicate-set-field
function ISEquipWeaponAction:perform()

    og_ISEquipWeaponAction_perform(self)

    -- TODO Can we do it earlier?
    local dcInst = DataController.GetInstance(self.character:getUsername())
    -- Just check it any limb has been cut. If not, we can just return from here
    if dcInst:getIsAnyLimbCut() == true then
        self:performWithAmputation(dcInst)
    end
end


function ISInventoryPaneContextMenu.doEquipOption(context, playerObj, isWeapon, items, player)
    
    
    -- check if hands if not heavy damaged
    if (not playerObj:isPrimaryHandItem(isWeapon) or (playerObj:isPrimaryHandItem(isWeapon) and playerObj:isSecondaryHandItem(isWeapon))) and not getSpecificPlayer(player):getBodyDamage():getBodyPart(BodyPartType.Hand_R):isDeepWounded() and (getSpecificPlayer(player):getBodyDamage():getBodyPart(BodyPartType.Hand_R):getFractureTime() == 0 or getSpecificPlayer(player):getBodyDamage():getBodyPart(BodyPartType.Hand_R):getSplintFactor() > 0)  then
        -- forbid reequipping skinned items to avoid multiple problems for now
        local add = true
        if playerObj:getSecondaryHandItem() == isWeapon and isWeapon:getScriptItem():getReplaceWhenUnequip() then
            add = false
        end
        if add then
            local equipOption = context:addOption(getText("ContextMenu_Equip_Primary"), items, ISInventoryPaneContextMenu.OnPrimaryWeapon, player)
            equipOption.notAvailable = not CheckHandFeasibility(StaticData.LIMBS_IND_STR.Hand_R)
        end


    end

    if (not playerObj:isSecondaryHandItem(isWeapon) or (playerObj:isPrimaryHandItem(isWeapon) and playerObj:isSecondaryHandItem(isWeapon))) and not getSpecificPlayer(player):getBodyDamage():getBodyPart(BodyPartType.Hand_L):isDeepWounded() and (getSpecificPlayer(player):getBodyDamage():getBodyPart(BodyPartType.Hand_L):getFractureTime() == 0 or getSpecificPlayer(player):getBodyDamage():getBodyPart(BodyPartType.Hand_L):getSplintFactor() > 0) then
        -- forbid reequipping skinned items to avoid multiple problems for now
        local add = true
        if playerObj:getPrimaryHandItem() == isWeapon and isWeapon:getScriptItem():getReplaceWhenUnequip() then
            add = false
        end
        if add then
            local equipOption = context:addOption(getText("ContextMenu_Equip_Secondary"), items, ISInventoryPaneContextMenu.OnSecondWeapon, player)

            equipOption.notAvailable = not CheckHandFeasibility(StaticData.LIMBS_IND_STR.Hand_L)

        end
    end
end


return LocalPlayerController