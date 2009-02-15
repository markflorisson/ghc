-----------------------------------------------------------------------------
--
-- The register liveness determinator
--
-- (c) The University of Glasgow 2004
--
-----------------------------------------------------------------------------
{-# OPTIONS -Wall -fno-warn-name-shadowing #-}

module RegAlloc.Liveness (
	RegSet,
	RegMap, emptyRegMap,
	BlockMap, emptyBlockMap,
	LiveCmmTop,
	LiveInstr (..),
	Liveness (..),
	LiveInfo (..),
	LiveBasicBlock,

	mapBlockTop, 	mapBlockTopM,
	mapGenBlockTop,	mapGenBlockTopM,
	stripLive,
	stripLiveBlock,
	slurpConflicts,
	slurpReloadCoalesce,
	eraseDeltasLive,
	patchEraseLive,
	patchRegsLiveInstr,
	regLiveness

  ) where


import Reg
import Instruction

import BlockId
import Cmm hiding (RegSet)
import PprCmm()

import Digraph
import Outputable
import Unique
import UniqSet
import UniqFM
import UniqSupply
import Bag
import State
import FastString

import Data.List
import Data.Maybe

-----------------------------------------------------------------------------
type RegSet = UniqSet Reg

type RegMap a = UniqFM a

emptyRegMap :: UniqFM a
emptyRegMap = emptyUFM

type BlockMap a = BlockEnv a

emptyBlockMap :: BlockEnv a
emptyBlockMap = emptyBlockEnv


-- | A top level thing which carries liveness information.
type LiveCmmTop instr
	= GenCmmTop
		CmmStatic
		LiveInfo
		(ListGraph (GenBasicBlock (LiveInstr instr)))
			-- the "instructions" here are actually more blocks,
			--	single blocks are acyclic
			--	multiple blocks are taken to be cyclic.

-- | An instruction with liveness information.
data LiveInstr instr
	= Instr instr (Maybe Liveness)

	-- | spill this reg to a stack slot
	| SPILL Reg Int

	-- | reload this reg from a stack slot
	| RELOAD Int Reg
	

-- | Liveness information.
-- 	The regs which die are ones which are no longer live in the *next* instruction
-- 	in this sequence.
-- 	(NB. if the instruction is a jump, these registers might still be live
-- 	at the jump target(s) - you have to check the liveness at the destination
-- 	block to find out).

data Liveness
	= Liveness
	{ liveBorn	:: RegSet	-- ^ registers born in this instruction (written to for first time).
	, liveDieRead	:: RegSet	-- ^ registers that died because they were read for the last time.
	, liveDieWrite	:: RegSet }	-- ^ registers that died because they were clobbered by something.


-- | Stash regs live on entry to each basic block in the info part of the cmm code.
data LiveInfo
	= LiveInfo
		[CmmStatic]		-- cmm static stuff
		(Maybe BlockId)		-- id of the first block
		(BlockMap RegSet)	-- argument locals live on entry to this block

-- | A basic block with liveness information.
type LiveBasicBlock instr
	= GenBasicBlock (LiveInstr instr)


instance Outputable instr 
      => Outputable (LiveInstr instr) where
	ppr (SPILL reg slot)
	   = hcat [
	   	ptext (sLit "\tSPILL"),
		char ' ',
		ppr reg,
		comma,
		ptext (sLit "SLOT") <> parens (int slot)]

	ppr (RELOAD slot reg)
	   = hcat [
	   	ptext (sLit "\tRELOAD"),
		char ' ',
		ptext (sLit "SLOT") <> parens (int slot),
		comma,
		ppr reg]

	ppr (Instr instr Nothing)
	 = ppr instr

	ppr (Instr instr (Just live))
	 =  ppr instr
		$$ (nest 8
			$ vcat
			[ pprRegs (ptext (sLit "# born:    ")) (liveBorn live)
			, pprRegs (ptext (sLit "# r_dying: ")) (liveDieRead live)
			, pprRegs (ptext (sLit "# w_dying: ")) (liveDieWrite live) ]
		    $+$ space)

	 where 	pprRegs :: SDoc -> RegSet -> SDoc
	 	pprRegs name regs
		 | isEmptyUniqSet regs	= empty
		 | otherwise		= name <> (hcat $ punctuate space $ map ppr $ uniqSetToList regs)

instance Outputable LiveInfo where
	ppr (LiveInfo static firstId liveOnEntry)
		=  (vcat $ map ppr static)
		$$ text "# firstId     = " <> ppr firstId
		$$ text "# liveOnEntry = " <> ppr liveOnEntry



-- | map a function across all the basic blocks in this code
--
mapBlockTop
	:: (LiveBasicBlock instr -> LiveBasicBlock instr)
	-> LiveCmmTop instr -> LiveCmmTop instr

mapBlockTop f cmm
	= evalState (mapBlockTopM (\x -> return $ f x) cmm) ()


-- | map a function across all the basic blocks in this code (monadic version)
--
mapBlockTopM
	:: Monad m
	=> (LiveBasicBlock instr -> m (LiveBasicBlock instr))
	-> LiveCmmTop instr -> m (LiveCmmTop instr)

mapBlockTopM _ cmm@(CmmData{})
	= return cmm

mapBlockTopM f (CmmProc header label params (ListGraph comps))
 = do	comps'	<- mapM (mapBlockCompM f) comps
 	return	$ CmmProc header label params (ListGraph comps')

mapBlockCompM :: Monad m => (a -> m a') -> (GenBasicBlock a) -> m (GenBasicBlock a')
mapBlockCompM f (BasicBlock i blocks)
 = do	blocks'	<- mapM f blocks
 	return	$ BasicBlock i blocks'


-- map a function across all the basic blocks in this code
mapGenBlockTop
	:: (GenBasicBlock             i -> GenBasicBlock            i)
	-> (GenCmmTop d h (ListGraph i) -> GenCmmTop d h (ListGraph i))

mapGenBlockTop f cmm
	= evalState (mapGenBlockTopM (\x -> return $ f x) cmm) ()


-- | map a function across all the basic blocks in this code (monadic version)
mapGenBlockTopM
	:: Monad m
	=> (GenBasicBlock            i  -> m (GenBasicBlock            i))
	-> (GenCmmTop d h (ListGraph i) -> m (GenCmmTop d h (ListGraph i)))

mapGenBlockTopM _ cmm@(CmmData{})
	= return cmm

mapGenBlockTopM f (CmmProc header label params (ListGraph blocks))
 = do	blocks'	<- mapM f blocks
 	return	$ CmmProc header label params (ListGraph blocks')


-- | Slurp out the list of register conflicts and reg-reg moves from this top level thing.
--	Slurping of conflicts and moves is wrapped up together so we don't have
--	to make two passes over the same code when we want to build the graph.
--
slurpConflicts 
	:: Instruction instr
	=> LiveCmmTop instr 
	-> (Bag (UniqSet Reg), Bag (Reg, Reg))

slurpConflicts live
	= slurpCmm (emptyBag, emptyBag) live

 where	slurpCmm   rs  CmmData{}		= rs
 	slurpCmm   rs (CmmProc info _ _ (ListGraph blocks))
		= foldl' (slurpComp info) rs blocks

	slurpComp  info rs (BasicBlock _ blocks)	
		= foldl' (slurpBlock info) rs blocks

	slurpBlock info rs (BasicBlock blockId instrs)	
		| LiveInfo _ _ blockLive	<- info
		, Just rsLiveEntry		<- lookupBlockEnv blockLive blockId
		, (conflicts, moves)		<- slurpLIs rsLiveEntry rs instrs
		= (consBag rsLiveEntry conflicts, moves)

		| otherwise
		= panic "Liveness.slurpConflicts: bad block"

	slurpLIs rsLive (conflicts, moves) []
		= (consBag rsLive conflicts, moves)

	slurpLIs rsLive rs (Instr _ Nothing     : lis)	
		= slurpLIs rsLive rs lis

	-- we're not expecting to be slurping conflicts from spilled code
	slurpLIs _ _ (SPILL _ _ : _)
		= panic "Liveness.slurpConflicts: unexpected SPILL"

	slurpLIs _ _ (RELOAD _ _ : _)
		= panic "Liveness.slurpConflicts: unexpected RELOAD"
		
	slurpLIs rsLiveEntry (conflicts, moves) (Instr instr (Just live) : lis)
	 = let
		-- regs that die because they are read for the last time at the start of an instruction
		--	are not live across it.
	 	rsLiveAcross	= rsLiveEntry `minusUniqSet` (liveDieRead live)

		-- regs live on entry to the next instruction.
		--	be careful of orphans, make sure to delete dying regs _after_ unioning
		--	in the ones that are born here.
	 	rsLiveNext 	= (rsLiveAcross `unionUniqSets` (liveBorn     live))
					        `minusUniqSet`  (liveDieWrite live)

		-- orphan vregs are the ones that die in the same instruction they are born in.
		--	these are likely to be results that are never used, but we still
		--	need to assign a hreg to them..
		rsOrphans	= intersectUniqSets
					(liveBorn live)
					(unionUniqSets (liveDieWrite live) (liveDieRead live))

		--
		rsConflicts	= unionUniqSets rsLiveNext rsOrphans

	  in	case takeRegRegMoveInstr instr of
	  	 Just rr	-> slurpLIs rsLiveNext
		 			( consBag rsConflicts conflicts
					, consBag rr moves) lis

	  	 Nothing	-> slurpLIs rsLiveNext
		 			( consBag rsConflicts conflicts
					, moves) lis


-- | For spill\/reloads
--
--	SPILL  v1, slot1
--	...
--	RELOAD slot1, v2
--
--	If we can arrange that v1 and v2 are allocated to the same hreg it's more likely
--	the spill\/reload instrs can be cleaned and replaced by a nop reg-reg move.
--
--
slurpReloadCoalesce 
	:: Instruction instr
	=> LiveCmmTop instr
	-> Bag (Reg, Reg)

slurpReloadCoalesce live
	= slurpCmm emptyBag live

 where	slurpCmm cs CmmData{}	= cs
 	slurpCmm cs (CmmProc _ _ _ (ListGraph blocks))
		= foldl' slurpComp cs blocks

	slurpComp  cs comp
	 = let	(moveBags, _)	= runState (slurpCompM comp) emptyUFM
	   in	unionManyBags (cs : moveBags)

	slurpCompM (BasicBlock _ blocks)
	 = do	-- run the analysis once to record the mapping across jumps.
	 	mapM_	(slurpBlock False) blocks

		-- run it a second time while using the information from the last pass.
		--	We /could/ run this many more times to deal with graphical control
		--	flow and propagating info across multiple jumps, but it's probably
		--	not worth the trouble.
		mapM	(slurpBlock True) blocks

	slurpBlock propagate (BasicBlock blockId instrs)
	 = do	-- grab the slot map for entry to this block
	 	slotMap		<- if propagate
					then getSlotMap blockId
					else return emptyUFM

	 	(_, mMoves)	<- mapAccumLM slurpLI slotMap instrs
	   	return $ listToBag $ catMaybes mMoves

	slurpLI :: Instruction instr
		=> UniqFM Reg 				-- current slotMap
		-> LiveInstr instr
		-> State (UniqFM [UniqFM Reg]) 		-- blockId -> [slot -> reg]
							-- 	for tracking slotMaps across jumps

			 ( UniqFM Reg			-- new slotMap
			 , Maybe (Reg, Reg))		-- maybe a new coalesce edge

	slurpLI slotMap li

		-- remember what reg was stored into the slot
		| SPILL reg slot	<- li
		, slotMap'		<- addToUFM slotMap slot reg
		= return (slotMap', Nothing)

		-- add an edge betwen the this reg and the last one stored into the slot
		| RELOAD slot reg	<- li
		= case lookupUFM slotMap slot of
			Just reg2
			 | reg /= reg2	-> return (slotMap, Just (reg, reg2))
			 | otherwise	-> return (slotMap, Nothing)

			Nothing		-> return (slotMap, Nothing)

		-- if we hit a jump, remember the current slotMap
		| Instr instr _		<- li
		, targets		<- jumpDestsOfInstr instr
		, not $ null targets
		= do	mapM_	(accSlotMap slotMap) targets
			return	(slotMap, Nothing)

		| otherwise
		= return (slotMap, Nothing)

	-- record a slotmap for an in edge to this block
	accSlotMap slotMap blockId
		= modify (\s -> addToUFM_C (++) s blockId [slotMap])

	-- work out the slot map on entry to this block
	--	if we have slot maps for multiple in-edges then we need to merge them.
	getSlotMap blockId
	 = do	map		<- get
	 	let slotMaps	= fromMaybe [] (lookupUFM map blockId)
		return		$ foldr mergeSlotMaps emptyUFM slotMaps

	mergeSlotMaps :: UniqFM Reg -> UniqFM Reg -> UniqFM Reg
	mergeSlotMaps map1 map2
		= listToUFM
		$ [ (k, r1)	| (k, r1)	<- ufmToList map1
				, case lookupUFM map2 k of
					Nothing	-> False
					Just r2	-> r1 == r2 ]


-- | Strip away liveness information, yielding NatCmmTop

stripLive 
	:: Instruction instr
	=> LiveCmmTop instr 
	-> NatCmmTop instr

stripLive live
	= stripCmm live

 where	stripCmm (CmmData sec ds)	= CmmData sec ds
 	stripCmm (CmmProc (LiveInfo info _ _) label params (ListGraph comps))
		= CmmProc info label params
                          (ListGraph $ concatMap stripComp comps)

	stripComp  (BasicBlock _ blocks)	= map stripLiveBlock blocks


-- | Strip away liveness information from a basic block,
--	and make real spill instructions out of SPILL, RELOAD pseudos along the way.

stripLiveBlock
	:: Instruction instr
	=> LiveBasicBlock instr
	-> NatBasicBlock instr

stripLiveBlock (BasicBlock i lis)
 = 	BasicBlock i instrs'

 where 	(instrs', _)
 		= runState (spillNat [] lis) 0

	spillNat acc []
	 = 	return (reverse acc)

	spillNat acc (SPILL reg slot : instrs)
	 = do	delta	<- get
	 	spillNat (mkSpillInstr reg delta slot : acc) instrs

	spillNat acc (RELOAD slot reg : instrs)
	 = do	delta	<- get
	 	spillNat (mkLoadInstr reg delta slot : acc) instrs

	spillNat acc (Instr instr _ : instrs)
	 | Just i <- takeDeltaInstr instr
	 = do	put i
	 	spillNat acc instrs

	spillNat acc (Instr instr _ : instrs)
	 =	spillNat (instr : acc) instrs


-- | Erase Delta instructions.

eraseDeltasLive 
	:: Instruction instr
	=> LiveCmmTop instr
	-> LiveCmmTop instr

eraseDeltasLive cmm
	= mapBlockTop eraseBlock cmm
 where
 	eraseBlock (BasicBlock id lis)
		= BasicBlock id
		$ filter (\(Instr i _) -> not $ isJust $ takeDeltaInstr i)
		$ lis


-- | Patch the registers in this code according to this register mapping.
--	also erase reg -> reg moves when the reg is the same.
--	also erase reg -> reg moves when the destination dies in this instr.

patchEraseLive
	:: Instruction instr
	=> (Reg -> Reg)
	-> LiveCmmTop instr -> LiveCmmTop instr

patchEraseLive patchF cmm
	= patchCmm cmm
 where
	patchCmm cmm@CmmData{}	= cmm

	patchCmm (CmmProc info label params (ListGraph comps))
	 | LiveInfo static id blockMap	<- info
	 = let 	patchRegSet set	= mkUniqSet $ map patchF $ uniqSetToList set
		blockMap'	= mapBlockEnv patchRegSet blockMap

		info'		= LiveInfo static id blockMap'
	   in	CmmProc info' label params $ ListGraph $ map patchComp comps

	patchComp (BasicBlock id blocks)
		= BasicBlock id $ map patchBlock blocks

 	patchBlock (BasicBlock id lis)
		= BasicBlock id $ patchInstrs lis

	patchInstrs []		= []
	patchInstrs (li : lis)

		| Instr i (Just live)	<- li'
		, Just (r1, r2)	<- takeRegRegMoveInstr i
		, eatMe r1 r2 live
		= patchInstrs lis

		| otherwise
		= li' : patchInstrs lis

		where	li'	= patchRegsLiveInstr patchF li

	eatMe	r1 r2 live
		-- source and destination regs are the same
		| r1 == r2	= True

		-- desination reg is never used
		| elementOfUniqSet r2 (liveBorn live)
		, elementOfUniqSet r2 (liveDieRead live) || elementOfUniqSet r2 (liveDieWrite live)
		= True

		| otherwise	= False


-- | Patch registers in this LiveInstr, including the liveness information.
--
patchRegsLiveInstr
	:: Instruction instr
	=> (Reg -> Reg)
	-> LiveInstr instr -> LiveInstr instr

patchRegsLiveInstr patchF li
 = case li of
	Instr instr Nothing
	 -> Instr (patchRegsOfInstr instr patchF) Nothing

	Instr instr (Just live)
	 -> Instr
	 	(patchRegsOfInstr instr patchF)
		(Just live
			{ -- WARNING: have to go via lists here because patchF changes the uniq in the Reg
			  liveBorn	= mkUniqSet $ map patchF $ uniqSetToList $ liveBorn live
			, liveDieRead	= mkUniqSet $ map patchF $ uniqSetToList $ liveDieRead live
			, liveDieWrite	= mkUniqSet $ map patchF $ uniqSetToList $ liveDieWrite live })

	SPILL reg slot
	 -> SPILL (patchF reg) slot
		
	RELOAD slot reg
	 -> RELOAD slot (patchF reg)


---------------------------------------------------------------------------------
-- Annotate code with register liveness information
--
regLiveness
	:: Instruction instr
	=> NatCmmTop instr
	-> UniqSM (LiveCmmTop instr)

regLiveness (CmmData i d)
	= returnUs $ CmmData i d

regLiveness (CmmProc info lbl params (ListGraph []))
	= returnUs $ CmmProc
			(LiveInfo info Nothing emptyBlockEnv)
			lbl params (ListGraph [])

regLiveness (CmmProc info lbl params (ListGraph blocks@(first : _)))
 = let 	first_id		= blockId first
	sccs			= sccBlocks blocks
	(ann_sccs, block_live)	= computeLiveness sccs

	liveBlocks
	 = map (\scc -> case scc of
	 		AcyclicSCC  b@(BasicBlock l _)		-> BasicBlock l [b]
			CyclicSCC  bs@(BasicBlock l _ : _)	-> BasicBlock l bs
			CyclicSCC  []
			 -> panic "RegLiveness.regLiveness: no blocks in scc list")
		 $ ann_sccs

   in	returnUs $ CmmProc (LiveInfo info (Just first_id) block_live)
			   lbl params (ListGraph liveBlocks)


sccBlocks 
	:: Instruction instr
	=> [NatBasicBlock instr] 
	-> [SCC (NatBasicBlock instr)]

sccBlocks blocks = stronglyConnCompFromEdgedVertices graph
  where
	getOutEdges :: Instruction instr => [instr] -> [BlockId]
	getOutEdges instrs = concat $ map jumpDestsOfInstr instrs

	graph = [ (block, getUnique id, map getUnique (getOutEdges instrs))
		| block@(BasicBlock id instrs) <- blocks ]


-- -----------------------------------------------------------------------------
-- Computing liveness

computeLiveness
	:: Instruction instr
	=> [SCC (NatBasicBlock instr)]
	-> ([SCC (LiveBasicBlock instr)],	-- instructions annotated with list of registers
						-- which are "dead after this instruction".
	       BlockMap RegSet)			-- blocks annontated with set of live registers
						-- on entry to the block.
	
  -- NOTE: on entry, the SCCs are in "reverse" order: later blocks may transfer
  -- control to earlier ones only.  The SCCs returned are in the *opposite* 
  -- order, which is exactly what we want for the next pass.

computeLiveness sccs
  	= livenessSCCs emptyBlockMap [] sccs


livenessSCCs
       :: Instruction instr
       => BlockMap RegSet
       -> [SCC (LiveBasicBlock instr)]		-- accum
       -> [SCC (NatBasicBlock instr)]
       -> ( [SCC (LiveBasicBlock instr)]
       	  , BlockMap RegSet)

livenessSCCs blockmap done [] = (done, blockmap)

livenessSCCs blockmap done (AcyclicSCC block : sccs)
 = let	(blockmap', block')	= livenessBlock blockmap block
   in	livenessSCCs blockmap' (AcyclicSCC block' : done) sccs

livenessSCCs blockmap done
	(CyclicSCC blocks : sccs) =
	livenessSCCs blockmap' (CyclicSCC blocks':done) sccs
 where      (blockmap', blocks')
	        = iterateUntilUnchanged linearLiveness equalBlockMaps
	                              blockmap blocks

            iterateUntilUnchanged
                :: (a -> b -> (a,c)) -> (a -> a -> Bool)
                -> a -> b
                -> (a,c)

	    iterateUntilUnchanged f eq a b
	        = head $
	          concatMap tail $
	          groupBy (\(a1, _) (a2, _) -> eq a1 a2) $
	          iterate (\(a, _) -> f a b) $
	          (a, panic "RegLiveness.livenessSCCs")


            linearLiveness 
	    	:: Instruction instr
		=> BlockMap RegSet -> [NatBasicBlock instr]
            	-> (BlockMap RegSet, [LiveBasicBlock instr])

            linearLiveness = mapAccumL livenessBlock

                -- probably the least efficient way to compare two
                -- BlockMaps for equality.
	    equalBlockMaps a b
	        = a' == b'
	      where a' = map f $ blockEnvToList a
	            b' = map f $ blockEnvToList b
	            f (key,elt) = (key, uniqSetToList elt)



-- | Annotate a basic block with register liveness information.
--
livenessBlock
	:: Instruction instr
	=> BlockMap RegSet
	-> NatBasicBlock instr
	-> (BlockMap RegSet, LiveBasicBlock instr)

livenessBlock blockmap (BasicBlock block_id instrs)
 = let
 	(regsLiveOnEntry, instrs1)
 		= livenessBack emptyUniqSet blockmap [] (reverse instrs)
 	blockmap'	= extendBlockEnv blockmap block_id regsLiveOnEntry

	instrs2		= livenessForward regsLiveOnEntry instrs1

	output		= BasicBlock block_id instrs2

   in	( blockmap', output)

-- | Calculate liveness going forwards,
--	filling in when regs are born

livenessForward
	:: Instruction instr
	=> RegSet			-- regs live on this instr
	-> [LiveInstr instr] -> [LiveInstr instr]

livenessForward _           []	= []
livenessForward rsLiveEntry (li@(Instr instr mLive) : lis)
	| Nothing		<- mLive
	= li : livenessForward rsLiveEntry lis

	| Just live	<- mLive
	, RU _ written	<- regUsageOfInstr instr
	= let
		-- Regs that are written to but weren't live on entry to this instruction
		--	are recorded as being born here.
		rsBorn		= mkUniqSet
				$ filter (\r -> not $ elementOfUniqSet r rsLiveEntry) written

		rsLiveNext	= (rsLiveEntry `unionUniqSets` rsBorn)
					`minusUniqSet` (liveDieRead live)
					`minusUniqSet` (liveDieWrite live)

	in Instr instr (Just live { liveBorn = rsBorn })
		: livenessForward rsLiveNext lis

livenessForward _ _ 		= panic "RegLiveness.livenessForward: no match"


-- | Calculate liveness going backwards,
--	filling in when regs die, and what regs are live across each instruction

livenessBack
	:: Instruction instr 
	=> RegSet			-- regs live on this instr
	-> BlockMap RegSet   		-- regs live on entry to other BBs
	-> [LiveInstr instr]   		-- instructions (accum)
	-> [instr]			-- instructions
	-> (RegSet, [LiveInstr instr])

livenessBack liveregs _        done []  = (liveregs, done)

livenessBack liveregs blockmap acc (instr : instrs)
 = let	(liveregs', instr')	= liveness1 liveregs blockmap instr
   in	livenessBack liveregs' blockmap (instr' : acc) instrs


-- don't bother tagging comments or deltas with liveness
liveness1 
	:: Instruction instr
	=> RegSet 
	-> BlockMap RegSet 
	-> instr
	-> (RegSet, LiveInstr instr)

liveness1 liveregs _ instr
	| isMetaInstr instr
	= (liveregs, Instr instr Nothing)

liveness1 liveregs blockmap instr

	| not_a_branch
	= (liveregs1, Instr instr
			(Just $ Liveness
			{ liveBorn	= emptyUniqSet
			, liveDieRead	= mkUniqSet r_dying
			, liveDieWrite	= mkUniqSet w_dying }))

	| otherwise
	= (liveregs_br, Instr instr
			(Just $ Liveness
			{ liveBorn	= emptyUniqSet
			, liveDieRead	= mkUniqSet r_dying_br
			, liveDieWrite	= mkUniqSet w_dying }))

	where
	    RU read written = regUsageOfInstr instr

	    -- registers that were written here are dead going backwards.
	    -- registers that were read here are live going backwards.
	    liveregs1   = (liveregs `delListFromUniqSet` written)
	                            `addListToUniqSet` read

	    -- registers that are not live beyond this point, are recorded
	    --  as dying here.
	    r_dying     = [ reg | reg <- read, reg `notElem` written,
	                      not (elementOfUniqSet reg liveregs) ]

	    w_dying     = [ reg | reg <- written,
	                     not (elementOfUniqSet reg liveregs) ]

	    -- union in the live regs from all the jump destinations of this
	    -- instruction.
	    targets      = jumpDestsOfInstr instr -- where we go from here
	    not_a_branch = null targets

	    targetLiveRegs target
                  = case lookupBlockEnv blockmap target of
                                Just ra -> ra
                                Nothing -> emptyRegMap

            live_from_branch = unionManyUniqSets (map targetLiveRegs targets)

	    liveregs_br = liveregs1 `unionUniqSets` live_from_branch

            -- registers that are live only in the branch targets should
            -- be listed as dying here.
            live_branch_only = live_from_branch `minusUniqSet` liveregs
            r_dying_br  = uniqSetToList (mkUniqSet r_dying `unionUniqSets`
                                        live_branch_only)




