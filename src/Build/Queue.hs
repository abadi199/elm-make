module Build.Queue where


newtype Queue a =
    Queue ([a], [a])


empty :: Queue a
empty =
    Queue ([],[])


size :: Queue a -> Int
size (Queue (front, back)) =
    length front + length back


enqueue :: [a] -> Queue a -> Queue a
enqueue names (Queue (front, back)) =
    Queue (front, names ++ back)


dequeue :: Int -> Queue a -> ([a], Queue a)
dequeue n (Queue (front, back)) =
    case splitAt n front of
        (names, []) ->
            let (names', front') = splitAt (length names) (reverse back)
            in
                (names ++ names', Queue (front', []))

        (names, front') ->
            (names, Queue (front', back))