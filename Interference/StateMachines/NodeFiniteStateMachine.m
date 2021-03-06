classdef NodeFiniteStateMachine < handle
    
    properties(Constant)
        BE = 3;
        maxBE = 5;
        SymbolsPerSlot = 4;
        RData = 250 * 1000;
        maxCSMABackoffs = 4;
        maxFrameRetries = 3;
        macAckWaitDuration = 54 / 4;
        TS = 0.000016; % Time per Slot
        LPhy = 6; % Length of the PHY header
        LMac_Hdr = 3; % Length of the MAC header
        LMac_Ftr = 2; % Length of the MAC footer
        LIFS = 40; % Long inter frame space
        SIFS = 12; % Short inter frame space
        TTa = 12; % Tournaround slots
        TBoSlots = 20; % Number of back off slot
        
        % Log Data indices%
        startSlotIndex = 1;
        endTransSlotIndex = 2;
        endAckSlotIndex = 3;
        endIfsSlotIndex = 4;
        transferredIndex = 5;
        payloadIndex = 6;
    end
    
    properties
        id;
        logDataList = [];
        state = 'idle';
        collision = false;
        stateStartSlot = 0;
        TTrans;
        TBo;
        TACK;
        frameRetries = 0;
        TIFS;
        send = 0;
        notSend = 0;
        CSMABackoffs = 0;
    end
    
    methods
        
        function obj = NodeFiniteStateMachine(varargin)
            if nargin > 0
                obj.id = varargin{1};  % 'id' is optional
            else
                obj.id = 0;
            end
        end
        
        function id = getId(obj)
            id = obj.id;
        end
        
        function send = getSend(obj)
            send = obj.send;
        end
        
        function notSend = getNotSend(obj)
            notSend = obj.notSend;
        end
        
        function reset(obj)
            obj.send = 0;
            obj.notSend = 0;
            obj.CSMABackoffs = 0;
        end
        
        function state = getState(obj)
            state = obj.state;
        end
        
        function nextStep(obj, slot, channelState)
            nextStep = obj.state;
            switch obj.state
                case 'cca'
                    if strcmp(channelState, 'clear')
                        nextStep = 'transmission';
                        obj.CSMABackoffs = 0;
                    else
                        obj.CSMABackoffs = obj.CSMABackoffs + 1;
                        if obj.CSMABackoffs > obj.maxCSMABackoffs
                            
                            % Set log data
                            obj.logDataList(end, obj.transferredIndex) = false;
                            
                            obj.notSend = obj.notSend + 1;
                            nextStep = 'idle';
                            
                            obj.CSMABackoffs = 0;
                        else
                            nextStep = 'backoff';
                            obj.setBackOffTime();
                        end
                    end
                case 'backoff'
                    if slot - obj.stateStartSlot >= obj.TBo
                        nextStep = 'cca';
                    end
                case 'transmission'
                    if strcmp(channelState, 'collision')
                        obj.collision = true;
                    end
                    
                    if slot - obj.stateStartSlot >= obj.TTrans
                        obj.logDataList(end, obj.endTransSlotIndex) = slot - obj.TACK;
                        
                        if obj.TACK
                            nextStep = 'ACK';
                        else
                            nextStep = 'IFS';
                        end
                    end
                    
                case 'ACK'
                    if strcmp(channelState, 'collision')
                        obj.collision = true;
                    end
                    
                    if slot - obj.stateStartSlot >= obj.TACK
                        
                        if obj.collision && obj.frameRetries < obj.maxFrameRetries
                            % Retransmit
                            % TODO: implement maxACKWait
                            
                            nextStep = 'backoff';
                            obj.frameRetries = obj.frameRetries + 1;
                        else
                            nextStep = 'IFS';
                            
                            obj.frameRetries = 0;
                            
                            % Set log data
                            obj.logDataList(end, obj.endAckSlotIndex) = slot;
                        end
                    end
                    
                case 'IFS'
                    if slot - obj.stateStartSlot >= obj.TIFS
                        nextStep = 'idle';
                        
                        if ~obj.collision
                            obj.send = obj.send + 1;
                        else
                            obj.notSend = obj.notSend + 1;
                        end
                        
                        % Set log data
                        obj.logDataList(end, obj.endIfsSlotIndex) = slot;
                        obj.logDataList(end, obj.transferredIndex) = ~obj.collision;
                    end
                    
            end
            
            if ~strcmp(obj.state, nextStep)
                obj.state = nextStep;
                obj.stateStartSlot = slot + 1;
            end
        end
        
        function sleepSlots = getMaxSleepSlots(obj, slot)
            slot = slot + 1; % calculating for next slot
            
            switch obj.state
                case 'backoff'
                    sleepSlots = obj.stateStartSlot + obj.TBo - slot;
                case 'transmission'
                    sleepSlots = obj.stateStartSlot + obj.TTrans - slot;
                case 'ACK'
                    sleepSlots = obj.stateStartSlot + obj.TACK - slot;
                case 'IFS'
                    sleepSlots = obj.stateStartSlot + obj.TIFS - slot;
                otherwise
                    sleepSlots = 0;
            end
            
        end
        
        function sendPacket(obj, slot, payload, addressLength, ack)
            obj.state = 'backoff';
            obj.setBackOffTime();
            obj.setTransmissionTime(payload, addressLength);
            obj.setACKTime(ack);
            obj.setIfsTime(payload, addressLength);
            obj.collision = false;
            
            logData(obj.startSlotIndex) = slot;
            logData(obj.payloadIndex) = payload;
            
            obj.logDataList = [obj.logDataList; logData];
            
        end
        
        function setBackOffTime(obj)
            rng('shuffle'); % kann auch weg
            BE = min(obj.BE + obj.CSMABackoffs, obj.maxBE); %#ok<PROP>
            obj.TBo = randi([0 (2^BE -1)]) * obj.TBoSlots; %#ok<PROP>
            % obj.TBo = 3.5 * TBoSlots(obj.TS);
        end
        
        function setTransmissionTime(obj,payload, addressLength)
            
            % Frame delay
            TFrame = @(x, LAddress) 8 * ...
                (obj.LPhy + obj.LMac_Hdr + LAddress + x + obj.LMac_Ftr )...
                / obj.SymbolsPerSlot;
            
            obj.TTrans = TFrame(payload, addressLength)...
                + obj.TTa;
        end
        
        function setIfsTime(obj, payload, LAddress)
            if (obj.LPhy + obj.LMac_Hdr + LAddress + payload...
                    + obj.LMac_Ftr <= 18) 
                obj.TIFS = obj.SIFS;
            else
                obj.TIFS = obj.LIFS;
            end
        end
        
        function setACKTime(obj, ack)
            % Acknowledgement delay
            if ack
                obj.TACK = 8 * (obj.LPhy + obj.LMac_Hdr + obj.LMac_Ftr)...
                    / obj.SymbolsPerSlot;
            else
                obj.TACK = 0;
            end
        end
        
        
        function throughputList = getThroughput(obj)
            if size(obj.logDataList, 1) == 0
                throughputList = [];
                return
            end
            
            throughputList(size(obj.logDataList), 1) = 0;
            
            for i = 1:size(obj.logDataList, 1)
                if obj.logDataList(i, obj.transferredIndex)
                    payload = obj.logDataList(i, obj.payloadIndex);
                    startSlot = obj.logDataList(i, obj.startSlotIndex);
                    endSlot = obj.logDataList(i, obj.endIfsSlotIndex);
                    
                    throughput = (payload * 8 / 1000)... % bits
                        / ((endSlot - startSlot) * obj.TS); % kbits
                else
                    throughput = 0;
                end
                
                throughputList(i) = throughput;
            end
        end
        
        function delayList = getDelay(obj)
            delayList = [];
            
            for i = 1:size(obj.logDataList, 1)
                if obj.logDataList(i, obj.transferredIndex)
                    startSlot = obj.logDataList(i, obj.startSlotIndex);
                    endSlot = obj.logDataList(i, obj.endIfsSlotIndex);
                    
                    delay = (endSlot - startSlot) * obj.TS; % s
                    
                    delayList = [delayList; delay]; %#ok<AGROW>
                end
            end
        end
    end
end

